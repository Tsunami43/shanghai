defmodule Query.Store do
  @moduledoc """
  Materialized key/value store backed by the Write-Ahead Log.

  `Query.Store` is the concrete implementation behind the public `Query` API.
  It maintains an in-memory index (an ETS table acting as a memtable) and,
  when the storage WAL is running, write-through appends every mutation to the
  log for durability. On start-up it replays the WAL to rebuild the in-memory
  state, giving crash recovery for free.

  ## Durability modes

  - **Durable** — when `Storage.WAL.Writer`/`Storage.WAL.Reader` are running
    (i.e. `:storage` is configured with a `:data_root`), every mutation is
    appended to the WAL before it becomes visible, and the store recovers its
    state from the WAL on restart.
  - **In-memory** — when the WAL is not running, the store still works as a
    fast in-memory KV, but data is not persisted. This keeps the umbrella and
    the test suite usable without a configured data directory.

  ## Record format

  Mutations are stored in the WAL as plain maps:

      %{op: :put, key: key, value: value}
      %{op: :delete, key: key}
      %{op: :txn, ops: [{:write, k, v} | {:delete, k}]}

  A transaction is a single WAL record, which makes it atomic on a single node:
  either all of its operations survive a crash, or none do.

  > Multi-node routing, quorum consistency and cross-node transactions are
  > layered on top of this store in the replication/query phases of the
  > roadmap. This module deliberately implements the single-node semantics.
  """

  use GenServer
  require Logger

  alias Storage.WAL.{Reader, Writer}

  @default_table :query_store

  ## Client API

  @doc """
  Starts the store.

  ## Options

  - `:name` - registered process name (default: `Query.Store`)
  - `:table` - ETS table name for the in-memory index (default: `:query_store`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reads the value stored under `key` from the default store.

  Returns `{:ok, value}` or `{:error, :not_found}`. Reads hit the ETS index
  directly for low latency and do not go through the owning process.
  """
  @spec get(term()) :: {:ok, term()} | {:error, :not_found | :store_unavailable}
  def get(key), do: lookup(@default_table, key)

  @doc """
  Reads `key` from a specific store instance (used for tests and embedding).
  """
  @spec get(GenServer.server(), term()) :: {:ok, term()} | {:error, :not_found}
  def get(server, key), do: GenServer.call(server, {:get, key})

  @doc """
  Reads several keys at once. Returns a map of the found `key => value` pairs;
  missing keys are omitted.
  """
  @spec mget([term()]) :: %{optional(term()) => term()}
  def mget(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case lookup(@default_table, key) do
        {:ok, value} -> Map.put(acc, key, value)
        _missing -> acc
      end
    end)
  end

  @doc "Returns every key currently stored, in unspecified order."
  @spec keys() :: [term()]
  def keys do
    :ets.select(@default_table, [{{:"$1", :"$2"}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Returns the number of stored keys."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@default_table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @doc """
  Returns all `{key, value}` pairs whose (binary) key starts with `prefix`.

  Non-binary keys are ignored. Results are sorted by key for a stable order.
  """
  @spec scan(binary()) :: [{binary(), term()}]
  def scan(prefix) when is_binary(prefix) do
    reducer = fn
      {key, value}, acc when is_binary(key) ->
        if String.starts_with?(key, prefix), do: [{key, value} | acc], else: acc

      _entry, acc ->
        acc
    end

    :ets.foldl(reducer, [], @default_table)
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  @doc "Writes `value` under `key`. Returns `{:ok, :written}`."
  @spec put(GenServer.server(), term(), term()) :: {:ok, :written} | {:error, term()}
  def put(server \\ __MODULE__, key, value), do: GenServer.call(server, {:put, key, value})

  @doc "Deletes `key`. Returns `{:ok, :deleted}` (idempotent)."
  @spec delete(GenServer.server(), term()) :: {:ok, :deleted} | {:error, term()}
  def delete(server \\ __MODULE__, key), do: GenServer.call(server, {:delete, key})

  @doc """
  Atomically reads and removes `key` (a pop). Returns `{:ok, value}` when the
  key existed, or `{:error, :not_found}`.
  """
  @spec take(GenServer.server(), term()) :: {:ok, term()} | {:error, :not_found | term()}
  def take(server \\ __MODULE__, key), do: GenServer.call(server, {:take, key})

  @doc "Writes `value` only if `key` is absent. Returns `{:ok, :written}` or `{:error, :exists}`."
  @spec put_new(GenServer.server(), term(), term()) :: {:ok, :written} | {:error, term()}
  def put_new(server \\ __MODULE__, key, value), do: GenServer.call(server, {:put_new, key, value})

  @doc "Writes `value` only if `key` exists. Returns `{:ok, :written}` or `{:error, :not_found}`."
  @spec replace(GenServer.server(), term(), term()) :: {:ok, :written} | {:error, term()}
  def replace(server \\ __MODULE__, key, value), do: GenServer.call(server, {:replace, key, value})

  @doc """
  Atomic compare-and-swap: writes `new` only if the current value matches
  `expected`. Pass `:absent` as `expected` to write only when the key is missing.

  Returns `{:ok, :swapped}` or `{:error, :precondition_failed}`.
  """
  @spec cas(GenServer.server(), term(), term() | :absent, term()) ::
          {:ok, :swapped} | {:error, term()}
  def cas(server \\ __MODULE__, key, expected, new),
    do: GenServer.call(server, {:cas, key, expected, new})

  @doc """
  Atomically adds `amount` to the numeric value at `key` (treated as `0` when
  absent). Returns `{:ok, new_value}`, or `{:error, :not_a_number}` if the
  stored value is not numeric.
  """
  @spec increment(GenServer.server(), term(), number()) :: {:ok, number()} | {:error, term()}
  def increment(server \\ __MODULE__, key, amount),
    do: GenServer.call(server, {:increment, key, amount})

  @doc """
  Atomic read-modify-write. Applies `fun` to the current value (or `default`
  when the key is absent) and stores the result. Returns `{:ok, new_value}`, or
  `{:error, {:update_failed, message}}` if `fun` raises.
  """
  @spec update(GenServer.server(), term(), term(), (term() -> term())) ::
          {:ok, term()} | {:error, term()}
  def update(server \\ __MODULE__, key, default, fun) when is_function(fun, 1),
    do: GenServer.call(server, {:update, key, default, fun})

  @doc """
  Deletes every (binary) key that starts with `prefix` as one atomic WAL record.
  Returns `{:ok, {:deleted, count}}` with the number of keys removed.
  """
  @spec delete_prefix(GenServer.server(), binary()) :: {:ok, {:deleted, non_neg_integer()}}
  def delete_prefix(server \\ __MODULE__, prefix) when is_binary(prefix),
    do: GenServer.call(server, {:delete_prefix, prefix})

  @doc """
  Atomically applies a list of `{:write, key, value}` / `{:delete, key}` ops.
  Returns `{:ok, :committed}`.
  """
  @spec transact(GenServer.server(), [tuple()]) :: {:ok, :committed} | {:error, term()}
  def transact(server \\ __MODULE__, ops), do: GenServer.call(server, {:transact, ops})

  @doc "Returns runtime information about the store."
  @spec info(GenServer.server()) :: {:ok, map()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Removes every key from the store's in-memory index.

  Intended for tests. It does not truncate the WAL, so a durable store would
  repopulate on the next recovery; use only against in-memory instances.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  ## Server callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    table = :ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])

    state = %{table: table, durable: wal_running?(), recovered: 0}

    state =
      if state.durable do
        recover(state)
      else
        Logger.info("Query.Store started in in-memory mode (WAL not running)")
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, lookup(state.table, key), state}
  end

  def handle_call({:put, key, value}, _from, state) do
    case append(state, %{op: :put, key: key, value: value}) do
      :ok ->
        :ets.insert(state.table, {key, value})
        {:reply, {:ok, :written}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cas, key, expected, new}, _from, state) do
    if cas_matches?(state.table, key, expected) do
      case append(state, %{op: :put, key: key, value: new}) do
        :ok ->
          :ets.insert(state.table, {key, new})
          {:reply, {:ok, :swapped}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :precondition_failed}, state}
    end
  end

  def handle_call({:update, key, default, fun}, _from, state) do
    current =
      case :ets.lookup(state.table, key) do
        [{^key, value}] -> value
        [] -> default
      end

    try do
      new_value = fun.(current)

      case append(state, %{op: :put, key: key, value: new_value}) do
        :ok ->
          :ets.insert(state.table, {key, new_value})
          {:reply, {:ok, new_value}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    rescue
      error ->
        {:reply, {:error, {:update_failed, Exception.message(error)}}, state}
    end
  end

  def handle_call({:increment, key, amount}, _from, state) do
    case current_number(state.table, key) do
      {:ok, current} ->
        new_value = current + amount

        case append(state, %{op: :put, key: key, value: new_value}) do
          :ok ->
            :ets.insert(state.table, {key, new_value})
            {:reply, {:ok, new_value}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_new, key, value}, _from, state) do
    if :ets.member(state.table, key) do
      {:reply, {:error, :exists}, state}
    else
      write_value(state, key, value)
    end
  end

  def handle_call({:replace, key, value}, _from, state) do
    if :ets.member(state.table, key) do
      write_value(state, key, value)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:take, key}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] ->
        case append(state, %{op: :delete, key: key}) do
          :ok ->
            :ets.delete(state.table, key)
            {:reply, {:ok, value}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    case append(state, %{op: :delete, key: key}) do
      :ok ->
        :ets.delete(state.table, key)
        {:reply, {:ok, :deleted}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_prefix, prefix}, _from, state) do
    keys = for {key, _value} <- scan(prefix), do: key

    case keys do
      [] ->
        {:reply, {:ok, {:deleted, 0}}, state}

      _ ->
        ops = Enum.map(keys, &{:delete, &1})

        case append(state, %{op: :txn, ops: ops}) do
          :ok ->
            Enum.each(ops, &apply_txn_op(state.table, &1))
            {:reply, {:ok, {:deleted, length(keys)}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:transact, ops}, _from, state) do
    with :ok <- validate_ops(ops),
         :ok <- append(state, %{op: :txn, ops: ops}) do
      Enum.each(ops, &apply_txn_op(state.table, &1))
      {:reply, {:ok, :committed}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      durable: state.durable,
      recovered: state.recovered,
      size: :ets.info(state.table, :size)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  ## Internal helpers

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :store_unavailable}
  end

  # Persists `key`/`value` and replies; shared by the conditional write paths.
  defp write_value(state, key, value) do
    case append(state, %{op: :put, key: key, value: value}) do
      :ok ->
        :ets.insert(state.table, {key, value})
        {:reply, {:ok, :written}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Reads the current numeric value at `key`, defaulting to 0 when absent.
  defp current_number(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] when is_number(value) -> {:ok, value}
      [{^key, _non_number}] -> {:error, :not_a_number}
      [] -> {:ok, 0}
    end
  end

  # CAS precondition: `:absent` matches a missing key; any other `expected`
  # matches only when the current value equals it.
  defp cas_matches?(table, key, :absent), do: :ets.lookup(table, key) == []

  defp cas_matches?(table, key, expected) do
    case :ets.lookup(table, key) do
      [{^key, ^expected}] -> true
      _ -> false
    end
  end

  defp wal_running? do
    is_pid(Process.whereis(Writer)) and
      is_pid(Process.whereis(Reader))
  end

  # Appends a record to the WAL when durable; a no-op in in-memory mode.
  defp append(%{durable: false}, _record), do: :ok

  defp append(%{durable: true}, record) do
    case Writer.append(record) do
      {:ok, _lsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Rebuilds the in-memory index by replaying the WAL from LSN 0.
  defp recover(state) do
    with {:ok, %{current_lsn: next_lsn}} when next_lsn > 0 <- Writer.info(),
         {:ok, entries} <- Reader.read_range(0, next_lsn - 1) do
      Enum.each(entries, fn %{data: record} -> apply_record(state.table, record) end)
      count = length(entries)
      Logger.info("Query.Store recovered #{count} WAL record(s)")
      %{state | recovered: count}
    else
      _ -> state
    end
  end

  defp apply_record(table, %{op: :put, key: key, value: value}),
    do: :ets.insert(table, {key, value})

  defp apply_record(table, %{op: :delete, key: key}), do: :ets.delete(table, key)

  defp apply_record(table, %{op: :txn, ops: ops}),
    do: Enum.each(ops, &apply_txn_op(table, &1))

  defp apply_record(_table, _unknown), do: :ok

  defp apply_txn_op(table, {:write, key, value}), do: :ets.insert(table, {key, value})
  defp apply_txn_op(table, {:delete, key}), do: :ets.delete(table, key)

  defp validate_ops(ops) when is_list(ops) do
    Enum.reduce_while(ops, :ok, fn
      {:write, _key, _value}, _acc -> {:cont, :ok}
      {:delete, _key}, _acc -> {:cont, :ok}
      other, _acc -> {:halt, {:error, {:invalid_operation, other}}}
    end)
  end

  defp validate_ops(_), do: {:error, :invalid_operations}
end
