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
      %{op: :clear}

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

  @doc "Returns the entire store as a map of `key => value`."
  @spec to_map() :: %{optional(term()) => term()}
  def to_map do
    @default_table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc "Returns the entire store as a list of `{key, value}` pairs, sorted by key."
  @spec to_list() :: [{term(), term()}]
  def to_list do
    @default_table |> :ets.tab2list() |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  @doc "Returns the smallest stored key by term order, or `nil` when empty."
  @spec min_key() :: term() | nil
  def min_key do
    case keys() do
      [] -> nil
      ks -> Enum.min(ks)
    end
  end

  @doc "Returns the largest stored key by term order, or `nil` when empty."
  @spec max_key() :: term() | nil
  def max_key do
    case keys() do
      [] -> nil
      ks -> Enum.max(ks)
    end
  end

  @doc "Returns `true` when `key` is present. Reads the ETS index directly."
  @spec exists?(term()) :: boolean()
  def exists?(key) do
    :ets.member(@default_table, key)
  rescue
    ArgumentError -> false
  end

  @doc "Counts the (binary) keys that start with `prefix`, without materializing them."
  @spec count_prefix(binary()) :: non_neg_integer()
  def count_prefix(prefix) when is_binary(prefix) do
    reducer = fn
      {key, _value}, acc when is_binary(key) ->
        if String.starts_with?(key, prefix), do: acc + 1, else: acc

      _entry, acc ->
        acc
    end

    :ets.foldl(reducer, 0, @default_table)
  rescue
    ArgumentError -> 0
  end

  @doc "Returns `true` when at least one key starts with `prefix`."
  @spec any_prefix?(binary()) :: boolean()
  def any_prefix?(prefix) when is_binary(prefix) do
    reducer = fn
      {key, _value}, _acc when is_binary(key) ->
        if String.starts_with?(key, prefix), do: throw(:found), else: false

      _entry, acc ->
        acc
    end

    :ets.foldl(reducer, false, @default_table)
  rescue
    ArgumentError -> false
  catch
    :found -> true
  end

  @doc """
  Returns `{key, value}` pairs whose (binary) key starts with `prefix`.

  Non-binary keys are ignored. Results are sorted by key for a stable order.
  Options:

  - `:limit` - return at most this many pairs (from the start of the sorted set)
  """
  @spec scan(binary(), keyword()) :: [{binary(), term()}]
  def scan(prefix, opts \\ []) when is_binary(prefix),
    do: scan_table(@default_table, prefix, opts)

  @doc "Returns the (binary) keys that start with `prefix`, sorted by key."
  @spec keys_prefix(binary()) :: [binary()]
  def keys_prefix(prefix) when is_binary(prefix) do
    for {key, _value} <- scan_table(@default_table, prefix, []), do: key
  end

  @doc "Returns the values whose (binary) key starts with `prefix`, in key order."
  @spec values_prefix(binary()) :: [term()]
  def values_prefix(prefix) when is_binary(prefix) do
    for {_key, value} <- scan_table(@default_table, prefix, []), do: value
  end

  @doc """
  Returns the keys within the inclusive range `[low, high]` by term order,
  sorted. Empty when `high` precedes `low`.
  """
  @spec keys_between(term(), term()) :: [term()]
  def keys_between(low, high) do
    keys()
    |> Enum.filter(&(&1 >= low and &1 <= high))
    |> Enum.sort()
  end

  @doc """
  Returns the number of keys within the inclusive range `[low, high]` without
  materializing them. `0` when `high` precedes `low`.
  """
  @spec count_between(term(), term()) :: non_neg_integer()
  def count_between(low, high) do
    Enum.count(keys(), &(&1 >= low and &1 <= high))
  end

  @doc """
  Returns the `{key, value}` pairs whose key falls within the inclusive range
  `[low, high]`, sorted by key. Empty when `high` precedes `low`.
  """
  @spec pairs_between(term(), term()) :: [{term(), term()}]
  def pairs_between(low, high) do
    @default_table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _value} -> key >= low and key <= high end)
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    ArgumentError -> []
  end

  # Prefix scan against a specific ETS table (the default store or a named
  # instance's table). Sorted by key; honors an optional `:limit`.
  defp scan_table(table, prefix, opts) do
    reducer = fn
      {key, value}, acc when is_binary(key) ->
        if String.starts_with?(key, prefix), do: [{key, value} | acc], else: acc

      _entry, acc ->
        acc
    end

    pairs =
      :ets.foldl(reducer, [], table)
      |> Enum.sort_by(&elem(&1, 0))

    case Keyword.get(opts, :limit) do
      nil -> pairs
      limit when is_integer(limit) and limit >= 0 -> Enum.take(pairs, limit)
      _ -> pairs
    end
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

  @doc """
  Deletes `key` only if its current value equals `expected`. Returns
  `{:ok, :deleted}`, `{:error, :precondition_failed}` on a mismatch, or
  `{:error, :not_found}` when the key is absent.
  """
  @spec delete_if(GenServer.server(), term(), term()) :: {:ok, :deleted} | {:error, term()}
  def delete_if(server \\ __MODULE__, key, expected),
    do: GenServer.call(server, {:delete_if, key, expected})

  @doc """
  Atomically writes `value` and returns the previous value: `{:ok, old}` when
  the key existed, or `{:ok, :absent}` when it did not.
  """
  @spec getset(GenServer.server(), term(), term()) :: {:ok, term() | :absent} | {:error, term()}
  def getset(server \\ __MODULE__, key, value), do: GenServer.call(server, {:getset, key, value})

  @doc "Writes `value` only if `key` is absent. Returns `{:ok, :written}` or `{:error, :exists}`."
  @spec put_new(GenServer.server(), term(), term()) :: {:ok, :written} | {:error, term()}
  def put_new(server \\ __MODULE__, key, value),
    do: GenServer.call(server, {:put_new, key, value})

  @doc "Writes `value` only if `key` exists. Returns `{:ok, :written}` or `{:error, :not_found}`."
  @spec replace(GenServer.server(), term(), term()) :: {:ok, :written} | {:error, term()}
  def replace(server \\ __MODULE__, key, value),
    do: GenServer.call(server, {:replace, key, value})

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
  Atomically moves the value at `from` to `to` (write `to` + delete `from` in a
  single WAL record). Returns `{:ok, :renamed}`, or `{:error, :not_found}` when
  `from` is absent.
  """
  @spec rename(GenServer.server(), term(), term()) :: {:ok, :renamed} | {:error, term()}
  def rename(server \\ __MODULE__, from, to), do: GenServer.call(server, {:rename, from, to})

  @doc """
  Copies the value at `from` to `to`, keeping `from`. Returns `{:ok, :copied}`,
  or `{:error, :not_found}` when `from` is absent.
  """
  @spec copy(GenServer.server(), term(), term()) :: {:ok, :copied} | {:error, term()}
  def copy(server \\ __MODULE__, from, to), do: GenServer.call(server, {:copy, from, to})

  @doc """
  Atomically swaps the values of `a` and `b` (both must exist) in a single WAL
  record. Returns `{:ok, :swapped}`, or `{:error, :not_found}` when either is
  absent.
  """
  @spec swap(GenServer.server(), term(), term()) :: {:ok, :swapped} | {:error, term()}
  def swap(server \\ __MODULE__, a, b), do: GenServer.call(server, {:swap, a, b})

  @doc """
  Deletes every (binary) key that starts with `prefix` as one atomic WAL record.
  Returns `{:ok, {:deleted, count}}` with the number of keys removed.
  """
  @spec delete_prefix(GenServer.server(), binary()) :: {:ok, {:deleted, non_neg_integer()}}
  def delete_prefix(server \\ __MODULE__, prefix) when is_binary(prefix),
    do: GenServer.call(server, {:delete_prefix, prefix})

  @doc """
  Atomic get-and-update (Access style). `fun` receives the current value (or
  `nil` when absent) and returns `{return_value, new_value}` to store `new_value`
  and reply `{:ok, return_value}`, or `:pop` to delete the key and reply
  `{:ok, current}`.
  """
  @spec get_and_update(GenServer.server(), term(), (term() -> {term(), term()} | :pop)) ::
          {:ok, term()} | {:error, term()}
  def get_and_update(server \\ __MODULE__, key, fun) when is_function(fun, 1),
    do: GenServer.call(server, {:get_and_update, key, fun})

  @doc """
  Atomic read-modify-write that only applies when `key` already exists. Returns
  `{:ok, new_value}`, or `{:error, :not_found}` when the key is absent.
  """
  @spec update_existing(GenServer.server(), term(), (term() -> term())) ::
          {:ok, term()} | {:error, term()}
  def update_existing(server \\ __MODULE__, key, fun) when is_function(fun, 1),
    do: GenServer.call(server, {:update_existing, key, fun})

  @doc """
  Atomically applies a list of `{:write, key, value}` / `{:delete, key}` ops.
  Returns `{:ok, :committed}`.
  """
  @spec transact(GenServer.server(), [tuple()]) :: {:ok, :committed} | {:error, term()}
  def transact(server \\ __MODULE__, ops), do: GenServer.call(server, {:transact, ops})

  @doc """
  Durably removes every key, persisting a `:clear` record to the WAL so the empty
  state survives a restart. Returns `{:ok, :cleared}`. Unlike `reset/1`, this is
  a real (durable) operation, not a test affordance.
  """
  @spec clear(GenServer.server()) :: {:ok, :cleared} | {:error, term()}
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear_all)

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

  def handle_call({:delete_if, key, expected}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, ^expected}] ->
        case append(state, %{op: :delete, key: key}) do
          :ok ->
            :ets.delete(state.table, key)
            {:reply, {:ok, :deleted}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [{^key, _other}] ->
        {:reply, {:error, :precondition_failed}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:getset, key, value}, _from, state) do
    previous =
      case :ets.lookup(state.table, key) do
        [{^key, old}] -> old
        [] -> :absent
      end

    case append(state, %{op: :put, key: key, value: value}) do
      :ok ->
        :ets.insert(state.table, {key, value})
        {:reply, {:ok, previous}, state}

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

  def handle_call({:get_and_update, key, fun}, _from, state) do
    current =
      case :ets.lookup(state.table, key) do
        [{^key, value}] -> value
        [] -> nil
      end

    try do
      case fun.(current) do
        {return_value, new_value} ->
          case append(state, %{op: :put, key: key, value: new_value}) do
            :ok ->
              :ets.insert(state.table, {key, new_value})
              {:reply, {:ok, return_value}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        :pop ->
          case append(state, %{op: :delete, key: key}) do
            :ok ->
              :ets.delete(state.table, key)
              {:reply, {:ok, current}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    rescue
      error ->
        {:reply, {:error, {:update_failed, Exception.message(error)}}, state}
    end
  end

  def handle_call({:update_existing, key, fun}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, current}] ->
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

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:rename, from, to}, _from, state) do
    case :ets.lookup(state.table, from) do
      [{^from, value}] ->
        ops = [{:write, to, value}, {:delete, from}]

        case append(state, %{op: :txn, ops: ops}) do
          :ok ->
            Enum.each(ops, &apply_txn_op(state.table, &1))
            {:reply, {:ok, :renamed}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:swap, a, b}, _from, state) do
    with [{^a, va}] <- :ets.lookup(state.table, a),
         [{^b, vb}] <- :ets.lookup(state.table, b) do
      ops = [{:write, a, vb}, {:write, b, va}]

      case append(state, %{op: :txn, ops: ops}) do
        :ok ->
          Enum.each(ops, &apply_txn_op(state.table, &1))
          {:reply, {:ok, :swapped}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      _absent -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:copy, from, to}, _from, state) do
    case :ets.lookup(state.table, from) do
      [{^from, value}] ->
        case append(state, %{op: :put, key: to, value: value}) do
          :ok ->
            :ets.insert(state.table, {to, value})
            {:reply, {:ok, :copied}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete_prefix, prefix}, _from, state) do
    keys = for {key, _value} <- scan_table(state.table, prefix, []), do: key

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
      size: :ets.info(state.table, :size),
      memory_bytes: table_memory_bytes(state.table)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, state) do
    case append(state, %{op: :clear}) do
      :ok ->
        :ets.delete_all_objects(state.table)
        {:reply, {:ok, :cleared}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  # Approximate memory footprint of the index table, in bytes. ETS reports
  # memory in words; convert using the emulator word size.
  defp table_memory_bytes(table) do
    case :ets.info(table, :memory) do
      words when is_integer(words) -> words * :erlang.system_info(:wordsize)
      _ -> 0
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

  defp apply_record(table, %{op: :clear}), do: :ets.delete_all_objects(table)

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
