defmodule Query do
  @moduledoc """
  Public API for read and write operations in the Shanghai database.

  This is the primary interface that clients use to interact with the database.
  All read and write operations go through this module, which coordinates with
  the underlying storage, replication, and cluster management layers.

  ## Examples

      # Write a key-value pair with strong consistency
      Query.write("user:1", %{name: "Alice", email: "alice@example.com"})

      # Read with eventual consistency
      Query.read("user:1", consistency: :eventual)

      # Execute a transaction
      Query.transact([
        {:write, "account:1", %{balance: 100}},
        {:write, "account:2", %{balance: 50}}
      ])
  """

  alias CoreDomain.ValueObjects.ConsistencyLevel

  @doc """
  Reads a value by key.

  ## Options

  - `:consistency` - Consistency level (:strong, :eventual, :causal). Default: :strong
  - `:timeout` - Read timeout in milliseconds. Default: 5000

  ## Examples

      iex> Query.read("user:1")
      {:ok, %{name: "Alice"}}

      iex> Query.read("nonexistent")
      {:error, :not_found}
  """
  @spec read(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def read(key, opts \\ []) do
    with :ok <- validate_consistency(opts) do
      # Consistency-aware routing to remote replicas is layered on top of the
      # local store in the replication phase; today reads resolve locally,
      # served from the read-through cache when possible.
      measure(:read, fn -> cached_read(key) end)
    end
  end

  @doc """
  Writes a key-value pair.

  ## Options

  - `:consistency` - Consistency level (:strong, :eventual). Default: :strong
  - `:timeout` - Write timeout in milliseconds. Default: 5000

  ## Examples

      iex> Query.write("user:1", %{name: "Alice"})
      {:ok, :written}
  """
  @spec write(String.t(), term(), keyword()) :: {:ok, :written} | {:error, term()}
  def write(key, value, opts \\ []) do
    with :ok <- validate_consistency(opts) do
      # Replication of the write to peer nodes happens in the replication phase;
      # the local store provides durability via the WAL.
      measure(:write, fn ->
        result = Query.Store.put(key, value)
        Query.Cache.invalidate(key)
        result
      end)
    end
  end

  @doc """
  Executes a transaction containing multiple operations.

  ## Examples

      iex> Query.transact([
      ...>   {:write, "key1", "value1"},
      ...>   {:write, "key2", "value2"}
      ...> ])
      {:ok, :committed}
  """
  @spec transact([{:write | :delete, String.t(), term()} | {:delete, String.t()}]) ::
          {:ok, :committed} | {:error, term()}
  def transact(operations) when is_list(operations) do
    # A transaction is persisted as a single WAL record, making it atomic on a
    # single node. Cross-node 2PC is introduced in the transactions phase.
    measure(:transact, fn ->
      result = Query.Store.transact(operations)
      if match?({:ok, _}, result), do: invalidate_ops(operations)
      result
    end)
  end

  @doc """
  Deletes a key.

  ## Examples

      iex> Query.delete("user:1")
      {:ok, :deleted}
  """
  @spec delete(String.t(), keyword()) :: {:ok, :deleted} | {:error, term()}
  def delete(key, _opts \\ []) do
    # Persisted as a tombstone in the WAL; compaction reclaims the space later.
    measure(:delete, fn ->
      result = Query.Store.delete(key)
      Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Writes `value` only if `key` does not exist yet.

  Returns `{:ok, :written}`, or `{:error, :exists}` if the key is already set.
  """
  @spec put_new(String.t(), term()) :: {:ok, :written} | {:error, term()}
  def put_new(key, value) do
    measure(:put_new, fn ->
      result = Query.Store.put_new(key, value)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Writes `value` only if `key` already exists.

  Returns `{:ok, :written}`, or `{:error, :not_found}` if the key is absent.
  """
  @spec replace(String.t(), term()) :: {:ok, :written} | {:error, term()}
  def replace(key, value) do
    measure(:replace, fn ->
      result = Query.Store.replace(key, value)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomically sets `key` to `value` and returns the previous value.

  Returns `{:ok, old}` when the key existed, or `{:ok, :absent}` when it did
  not. Handy for claiming a slot while learning what it held before.

  ## Examples

      iex> Query.getset("leader", "node-a")
      {:ok, :absent}

      iex> Query.getset("leader", "node-b")
      {:ok, "node-a"}
  """
  @spec getset(String.t(), term()) :: {:ok, term() | :absent} | {:error, term()}
  def getset(key, value) do
    measure(:getset, fn ->
      result = Query.Store.getset(key, value)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomically reads and removes `key` (a pop), returning `{:ok, value}` or
  `{:error, :not_found}`. Useful for queue/work-stealing patterns.

  ## Examples

      iex> Query.write("job:1", %{task: :send})
      iex> Query.take("job:1")
      {:ok, %{task: :send}}
  """
  @spec take(String.t()) :: {:ok, term()} | {:error, :not_found}
  def take(key) do
    measure(:take, fn ->
      result = Query.Store.take(key)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomic compare-and-swap for optimistic concurrency.

  Writes `new` only if the current value equals `expected`; pass `:absent` to
  write only when the key does not exist. Returns `{:ok, :swapped}` or
  `{:error, :precondition_failed}`.

  ## Examples

      iex> Query.cas("counter", :absent, 1)
      {:ok, :swapped}

      iex> Query.cas("counter", 1, 2)
      {:ok, :swapped}
  """
  @spec cas(String.t(), term() | :absent, term()) :: {:ok, :swapped} | {:error, term()}
  def cas(key, expected, new) do
    measure(:cas, fn ->
      result = Query.Store.cas(key, expected, new)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomic read-modify-write. Applies `fun` to the current value (or `default`
  when the key is absent) and stores the result, returning `{:ok, new_value}`.

  ## Examples

      iex> Query.update("tags", [], &["new" | &1])
      {:ok, ["new"]}
  """
  @spec update(String.t(), term(), (term() -> term())) :: {:ok, term()} | {:error, term()}
  def update(key, default, fun) when is_function(fun, 1) do
    measure(:update, fn ->
      result = Query.Store.update(key, default, fun)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomically adds `amount` (default `1`) to the numeric value at `key`,
  treating a missing key as `0`. Returns `{:ok, new_value}`.

  ## Examples

      iex> Query.increment("hits")
      {:ok, 1}

      iex> Query.increment("hits", 5)
      {:ok, 6}
  """
  @spec increment(String.t(), number()) :: {:ok, number()} | {:error, term()}
  def increment(key, amount \\ 1) when is_number(amount) do
    measure(:increment, fn ->
      result = Query.Store.increment(key, amount)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Deletes every key that starts with `prefix`, returning `{:ok, {:deleted, count}}`.

  The removal is a single atomic WAL record — either all matching keys are gone
  after a crash, or none are. Useful for evicting an entity's whole key range.

  ## Examples

      iex> Query.write("session:1:a", 1)
      iex> Query.write("session:1:b", 2)
      iex> Query.delete_prefix("session:1:")
      {:ok, {:deleted, 2}}
  """
  @spec delete_prefix(binary()) :: {:ok, {:deleted, non_neg_integer()}} | {:error, term()}
  def delete_prefix(prefix) when is_binary(prefix) do
    measure(:delete_prefix, fn ->
      keys = Query.Store.scan(prefix) |> Enum.map(&elem(&1, 0))
      result = Query.Store.delete_prefix(prefix)
      if match?({:ok, _}, result), do: Enum.each(keys, &Query.Cache.invalidate/1)
      result
    end)
  end

  @doc """
  Returns all `{key, value}` pairs whose key starts with `prefix`.

  Useful for range/collection access patterns (event streams, per-entity keys).

  ## Examples

      iex> Query.scan("events:order-1:")
      {:ok, [{"events:order-1:1", ...}, {"events:order-1:2", ...}]}
  """
  @spec scan(binary()) :: {:ok, [{binary(), term()}]}
  def scan(prefix) when is_binary(prefix) do
    measure(:scan, fn -> {:ok, Query.Store.scan(prefix)} end)
  end

  @doc """
  Writes several key/value pairs at once as one atomic WAL record.

  Accepts a map or a keyword/tuple list. Returns `{:ok, :committed}`. This is
  the write counterpart to `mget/1` — either every pair survives a crash or none
  does.

  ## Examples

      iex> Query.mset(%{"a" => 1, "b" => 2})
      {:ok, :committed}
  """
  @spec mset(map() | [{String.t(), term()}]) :: {:ok, :committed} | {:error, term()}
  def mset(pairs) when is_map(pairs) or is_list(pairs) do
    ops = for {key, value} <- pairs, do: {:write, key, value}

    measure(:mset, fn ->
      result = Query.Store.transact(ops)

      if match?({:ok, _}, result),
        do: Enum.each(ops, fn {:write, k, _v} -> Query.Cache.invalidate(k) end)

      result
    end)
  end

  @doc """
  Reads several keys at once, returning `{:ok, %{key => value}}` for the keys
  that exist (missing keys are omitted).

  ## Examples

      iex> Query.mget(["a", "b", "missing"])
      {:ok, %{"a" => 1, "b" => 2}}
  """
  @spec mget([String.t()]) :: {:ok, %{optional(String.t()) => term()}}
  def mget(keys) when is_list(keys) do
    measure(:mget, fn -> {:ok, Query.Store.mget(keys)} end)
  end

  @doc """
  Returns a runtime summary of the query layer: the store's durability mode,
  the number of records recovered on start, the live key count, and cache stats.

  ## Examples

      iex> {:ok, info} = Query.info()
      iex> is_boolean(info.store.durable) and is_integer(info.cache.size)
      true
  """
  @spec info() :: {:ok, %{store: map(), cache: map()}}
  def info do
    {:ok, store} = Query.Store.info()
    {:ok, cache} = Query.Cache.stats()
    {:ok, %{store: store, cache: cache}}
  end

  @doc """
  Returns `true` when `key` exists. A cheap membership check that avoids
  fetching the value.

  ## Examples

      iex> Query.write("k", 1)
      iex> Query.exists?("k")
      true
  """
  @spec exists?(String.t()) :: boolean()
  defdelegate exists?(key), to: Query.Store

  @doc """
  Counts the keys that start with `prefix` without materializing them — the
  cheap counterpart to `scan/1`.

  ## Examples

      iex> Query.mset(%{"e:1" => 1, "e:2" => 2})
      iex> Query.count_prefix("e:")
      2
  """
  @spec count_prefix(binary()) :: non_neg_integer()
  defdelegate count_prefix(prefix), to: Query.Store

  @doc "Returns every stored key."
  @spec keys() :: [term()]
  defdelegate keys(), to: Query.Store

  @doc "Returns the number of stored keys."
  @spec count() :: non_neg_integer()
  defdelegate count(), to: Query.Store

  # Validates the requested consistency level, if any was provided.
  defp validate_consistency(opts) do
    level = Keyword.get(opts, :consistency, ConsistencyLevel.default())

    if ConsistencyLevel.valid?(level) do
      :ok
    else
      {:error, {:invalid_consistency, level}}
    end
  end

  # Runs `fun`, timing it and emitting a `[:shanghai, :query, :operation]`
  # telemetry event — the query layer is observable by default.
  defp measure(operation, fun) do
    start = System.monotonic_time()
    result = fun.()

    duration_ms =
      (System.monotonic_time() - start)
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1000)

    Observability.Metrics.query_operation_completed(operation, duration_ms, result_tag(result))
    result
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag(_), do: :error

  # Read-through cache: serve from cache on a hit, otherwise fetch from the
  # store and populate the cache on success.
  defp cached_read(key) do
    case Query.Cache.get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case Query.Store.get(key) do
          {:ok, value} = ok ->
            Query.Cache.put(key, value)
            ok

          other ->
            other
        end
    end
  end

  defp invalidate_ops(operations) do
    Enum.each(operations, fn
      {:write, key, _value} -> Query.Cache.invalidate(key)
      {:delete, key} -> Query.Cache.invalidate(key)
      _ -> :ok
    end)
  end
end
