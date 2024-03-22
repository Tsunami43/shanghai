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
  Reads `key`, returning the bare value when present or `default` otherwise —
  an ergonomic wrapper over `read/2` for when the `{:ok, _}`/`{:error, _}` shape
  is not needed.

  ## Examples

      iex> Query.write("k", 1)
      iex> Query.get("k")
      1

      iex> Query.get("missing", :none)
      :none
  """
  @spec get(String.t(), term()) :: term()
  def get(key, default \\ nil) do
    case read(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  @doc """
  Reads `key`, returning the bare value or raising `KeyError` when it is absent.
  The strict counterpart to `get/2`.
  """
  @spec fetch!(String.t()) :: term()
  def fetch!(key) do
    case read(key) do
      {:ok, value} -> value
      {:error, _reason} -> raise KeyError, key: key, term: __MODULE__
    end
  end

  @doc """
  Reads `key`, returning its value when present or the result of calling `fun`
  otherwise. Unlike `get/2`, the fallback is computed lazily — only on a miss.
  """
  @spec get_lazy(String.t(), (-> term())) :: term()
  def get_lazy(key, fun) when is_function(fun, 0) do
    case read(key) do
      {:ok, value} -> value
      {:error, _reason} -> fun.()
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
  Returns the value at `key`, or computes it with `fun`, stores it, and returns
  it when the key is absent (get-or-compute).

  The store step is race-safe: if another writer populates the key first, the
  already-stored value is returned and `fun`'s result is discarded.

  ## Examples

      iex> Query.get_or_store("config", fn -> %{loaded: true} end)
      {:ok, %{loaded: true}}
  """
  @spec get_or_store(String.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  def get_or_store(key, fun) when is_function(fun, 0) do
    case read(key) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        value = fun.()

        case put_new(key, value) do
          {:ok, :written} -> {:ok, value}
          {:error, :exists} -> read(key)
          other -> other
        end

      other ->
        other
    end
  end

  @doc """
  Atomically renames `from` to `to`, moving the value in a single WAL record.

  Returns `{:ok, :renamed}`, or `{:error, :not_found}` when `from` does not
  exist. Any existing value at `to` is overwritten.

  ## Examples

      iex> Query.write("draft:1", "text")
      iex> Query.rename("draft:1", "post:1")
      {:ok, :renamed}
  """
  @spec rename(String.t(), String.t()) :: {:ok, :renamed} | {:error, term()}
  def rename(from, to) do
    measure(:rename, fn ->
      result = Query.Store.rename(from, to)
      if match?({:ok, _}, result), do: Query.Cache.invalidate_many([from, to])
      result
    end)
  end

  @doc """
  Copies the value at `from` to `to`, keeping `from`.

  Returns `{:ok, :copied}`, or `{:error, :not_found}` when `from` does not
  exist. Any existing value at `to` is overwritten.

  ## Examples

      iex> Query.write("template", %{fields: []})
      iex> Query.copy("template", "doc:1")
      {:ok, :copied}
  """
  @spec copy(String.t(), String.t()) :: {:ok, :copied} | {:error, term()}
  def copy(from, to) do
    measure(:copy, fn ->
      result = Query.Store.copy(from, to)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(to)
      result
    end)
  end

  @doc """
  Atomically swaps the values of `a` and `b` in a single WAL record.

  Both keys must exist. Returns `{:ok, :swapped}`, or `{:error, :not_found}`
  when either key is absent.

  ## Examples

      iex> Query.write("a", 1)
      iex> Query.write("b", 2)
      iex> Query.swap("a", "b")
      {:ok, :swapped}
  """
  @spec swap(String.t(), String.t()) :: {:ok, :swapped} | {:error, term()}
  def swap(a, b) do
    measure(:swap, fn ->
      result = Query.Store.swap(a, b)
      if match?({:ok, _}, result), do: Query.Cache.invalidate_many([a, b])

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
  Deletes `key` only if its current value equals `expected` (conditional delete).

  Returns `{:ok, :deleted}`, `{:error, :precondition_failed}` if the value does
  not match, or `{:error, :not_found}` when the key is absent.

  ## Examples

      iex> Query.write("lock", "owner-a")
      iex> Query.delete_if("lock", "owner-a")
      {:ok, :deleted}
  """
  @spec delete_if(String.t(), term()) :: {:ok, :deleted} | {:error, term()}
  def delete_if(key, expected) do
    measure(:delete_if, fn ->
      result = Query.Store.delete_if(key, expected)
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
  Atomically appends `element` to the list stored at `key`, creating an empty
  list first when the key is absent. Returns `{:ok, new_list}`.

  ## Examples

      iex> Query.append("items", :a)
      {:ok, [:a]}
      iex> Query.append("items", :b)
      {:ok, [:a, :b]}
  """
  @spec append(String.t(), term()) :: {:ok, [term()]} | {:error, term()}
  def append(key, element) do
    update(key, [], fn list -> list ++ [element] end)
  end

  @doc """
  Atomically prepends `element` to the list stored at `key`, creating an empty
  list first when the key is absent. Returns `{:ok, new_list}`.
  """
  @spec prepend(String.t(), term()) :: {:ok, [term()]} | {:error, term()}
  def prepend(key, element) do
    update(key, [], fn list -> [element | list] end)
  end

  @doc """
  Atomically adds `element` to the list stored at `key` only when it is not
  already present (set semantics, preserving insertion order). Creates an empty
  list when the key is absent. Returns `{:ok, new_list}`.
  """
  @spec add_to_set(String.t(), term()) :: {:ok, [term()]} | {:error, term()}
  def add_to_set(key, element) do
    update(key, [], fn list ->
      if element in list, do: list, else: list ++ [element]
    end)
  end

  @doc """
  Atomically removes every occurrence of `element` from the list stored at
  `key`. A no-op when the key is absent. Returns `{:ok, new_list}`.
  """
  @spec remove_from_list(String.t(), term()) :: {:ok, [term()]} | {:error, term()}
  def remove_from_list(key, element) do
    update(key, [], fn list -> Enum.reject(list, &(&1 == element)) end)
  end

  @doc """
  Atomically sets `field` to `value` in the map stored at `key`, creating an
  empty map when the key is absent. Returns `{:ok, new_map}`.
  """
  @spec put_field(String.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def put_field(key, field, value) do
    update(key, %{}, fn map -> Map.put(map, field, value) end)
  end

  @doc """
  Atomically removes `field` from the map stored at `key`. A no-op when the key
  or field is absent. Returns `{:ok, new_map}`.
  """
  @spec delete_field(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def delete_field(key, field) do
    update(key, %{}, fn map -> Map.delete(map, field) end)
  end

  @doc """
  Atomically adds `amount` (default `1`) to the numeric `field` in the map
  stored at `key`, treating a missing field or key as `0`. Returns
  `{:ok, new_map}`.
  """
  @spec increment_field(String.t(), term(), number()) :: {:ok, map()} | {:error, term()}
  def increment_field(key, field, amount \\ 1) when is_number(amount) do
    update(key, %{}, fn map ->
      Map.update(map, field, amount, &(&1 + amount))
    end)
  end

  @doc """
  Atomically subtracts `amount` (default `1`) from the numeric `field` in the
  map stored at `key`, treating a missing field or key as `0`. Returns
  `{:ok, new_map}`.
  """
  @spec decrement_field(String.t(), term(), number()) :: {:ok, map()} | {:error, term()}
  def decrement_field(key, field, amount \\ 1) when is_number(amount) do
    increment_field(key, field, -amount)
  end

  @doc """
  Reads `field` from the map stored at `key`, returning `default` when the key
  is absent, holds a non-map, or lacks the field. A read-only accessor.
  """
  @spec get_field(String.t(), term(), term()) :: term()
  def get_field(key, field, default \\ nil) do
    case read(key) do
      {:ok, map} when is_map(map) -> Map.get(map, field, default)
      _ -> default
    end
  end

  @doc """
  Returns `true` when the map stored at `key` contains `field`. `false` when the
  key is absent or does not hold a map. A read-only accessor.
  """
  @spec has_field?(String.t(), term()) :: boolean()
  def has_field?(key, field) do
    case read(key) do
      {:ok, map} when is_map(map) -> Map.has_key?(map, field)
      _ -> false
    end
  end

  @doc """
  Atomically removes `field` from the map stored at `key`, returning
  `{:ok, removed_value}`. When the key is absent, holds a non-map, or lacks the
  field, nothing is written and `{:ok, default}` is returned.
  """
  @spec pop_field(String.t(), term(), term()) :: {:ok, term()} | {:error, term()}
  def pop_field(key, field, default \\ nil) do
    if has_field?(key, field) do
      get_and_update(key, fn map -> {Map.get(map, field), Map.delete(map, field)} end)
    else
      {:ok, default}
    end
  end

  @doc """
  Returns `true` when the list stored at `key` contains `element`. `false` when
  the key is absent or does not hold a list. A read-only accessor.
  """
  @spec list_member?(String.t(), term()) :: boolean()
  def list_member?(key, element) do
    case read(key) do
      {:ok, list} when is_list(list) -> element in list
      _ -> false
    end
  end

  @doc """
  Returns the length of the list stored at `key`, or `0` when the key is absent
  or does not hold a list. A read-only accessor.
  """
  @spec list_length(String.t()) :: non_neg_integer()
  def list_length(key) do
    case read(key) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end

  @doc """
  Atomic get-and-update in the `Access` style.

  `fun` receives the current value (or `nil` when absent) and returns
  `{return_value, new_value}` — `new_value` is stored and `{:ok, return_value}`
  is returned — or `:pop` to delete the key and return the previous value.

  ## Examples

      iex> Query.write("counter", 5)
      iex> Query.get_and_update("counter", fn v -> {v, v + 1} end)
      {:ok, 5}
  """
  @spec get_and_update(String.t(), (term() -> {term(), term()} | :pop)) ::
          {:ok, term()} | {:error, term()}
  def get_and_update(key, fun) when is_function(fun, 1) do
    measure(:get_and_update, fn ->
      result = Query.Store.get_and_update(key, fun)
      if match?({:ok, _}, result), do: Query.Cache.invalidate(key)
      result
    end)
  end

  @doc """
  Atomic read-modify-write that only applies when `key` already exists.

  Applies `fun` to the current value and stores the result, returning
  `{:ok, new_value}`, or `{:error, :not_found}` when the key is absent. Unlike
  `update/3`, it never creates the key.

  ## Examples

      iex> Query.write("counter", 1)
      iex> Query.update_existing("counter", &(&1 + 1))
      {:ok, 2}

      iex> Query.update_existing("missing", &(&1 + 1))
      {:error, :not_found}
  """
  @spec update_existing(String.t(), (term() -> term())) :: {:ok, term()} | {:error, term()}
  def update_existing(key, fun) when is_function(fun, 1) do
    measure(:update_existing, fn ->
      result = Query.Store.update_existing(key, fun)
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
  Atomically subtracts `amount` (default `1`) from the numeric value at `key`,
  treating a missing key as `0`. Returns `{:ok, new_value}`.

  ## Examples

      iex> Query.write("stock", 10)
      iex> Query.decrement("stock", 3)
      {:ok, 7}
  """
  @spec decrement(String.t(), number()) :: {:ok, number()} | {:error, term()}
  def decrement(key, amount \\ 1) when is_number(amount) do
    measure(:decrement, fn ->
      result = Query.Store.increment(key, -amount)
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
      if match?({:ok, _}, result), do: Query.Cache.invalidate_many(keys)
      result
    end)
  end

  @doc """
  Returns `{key, value}` pairs whose key starts with `prefix`, sorted by key.

  Useful for range/collection access patterns (event streams, per-entity keys).
  Pass `limit:` to cap the number of pairs returned (pagination for large sets).

  ## Examples

      iex> Query.scan("events:order-1:")
      {:ok, [{"events:order-1:1", ...}, {"events:order-1:2", ...}]}

      iex> Query.scan("events:order-1:", limit: 1)
      {:ok, [{"events:order-1:1", ...}]}
  """
  @spec scan(binary(), keyword()) :: {:ok, [{binary(), term()}]}
  def scan(prefix, opts \\ []) when is_binary(prefix) do
    measure(:scan, fn -> {:ok, Query.Store.scan(prefix, opts)} end)
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
        do: Query.Cache.invalidate_many(for {:write, k, _v} <- ops, do: k)

      result
    end)
  end

  @doc """
  Deletes several keys at once as one atomic WAL record.

  Returns `{:ok, :committed}`. Idempotent for keys that do not exist. This is the
  delete counterpart to `mset/1`.

  ## Examples

      iex> Query.mdelete(["a", "b"])
      {:ok, :committed}
  """
  @spec mdelete([String.t()]) :: {:ok, :committed} | {:error, term()}
  def mdelete(keys) when is_list(keys) do
    ops = for key <- keys, do: {:delete, key}

    measure(:mdelete, fn ->
      result = Query.Store.transact(ops)
      if match?({:ok, _}, result), do: Query.Cache.invalidate_many(keys)
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
  Returns the subset of `keys` that are not present in the store, preserving the
  input order. The complement of the keys returned by `mget/1`.

  ## Examples

      iex> Query.write("a", 1)
      iex> Query.missing(["a", "b", "c"])
      ["b", "c"]
  """
  @spec missing([String.t()]) :: [String.t()]
  def missing(keys) when is_list(keys) do
    Enum.reject(keys, &Query.Store.exists?/1)
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

  @doc "Returns `true` when at least one key starts with `prefix`."
  @spec any_prefix?(binary()) :: boolean()
  defdelegate any_prefix?(prefix), to: Query.Store

  @doc """
  Durably removes every key from the store and flushes the cache. Returns
  `{:ok, :cleared}`. The empty state is persisted to the WAL, so it survives a
  restart.
  """
  @spec clear() :: {:ok, :cleared} | {:error, term()}
  def clear do
    measure(:clear, fn ->
      result = Query.Store.clear()
      if match?({:ok, _}, result), do: Query.Cache.clear()
      result
    end)
  end

  @doc "Returns every stored key."
  @spec keys() :: [term()]
  defdelegate keys(), to: Query.Store

  @doc "Returns the keys that start with `prefix`, sorted."
  @spec keys_prefix(binary()) :: [binary()]
  defdelegate keys_prefix(prefix), to: Query.Store

  @doc "Returns the values whose key starts with `prefix`, in key order."
  @spec values_prefix(binary()) :: [term()]
  defdelegate values_prefix(prefix), to: Query.Store

  @doc "Returns the keys within the inclusive range `[low, high]`, sorted."
  @spec keys_between(term(), term()) :: [term()]
  defdelegate keys_between(low, high), to: Query.Store

  @doc "Returns the `{key, value}` pairs within the inclusive range `[low, high]`, sorted."
  @spec pairs_between(term(), term()) :: [{term(), term()}]
  defdelegate pairs_between(low, high), to: Query.Store

  @doc "Returns the number of stored keys."
  @spec count() :: non_neg_integer()
  defdelegate count(), to: Query.Store

  @doc "Returns the entire store as a map of `key => value`."
  @spec to_map() :: %{optional(term()) => term()}
  defdelegate to_map(), to: Query.Store

  @doc "Returns the entire store as a list of `{key, value}` pairs, sorted by key."
  @spec to_list() :: [{term(), term()}]
  defdelegate to_list(), to: Query.Store

  @doc "Returns the smallest stored key, or `nil` when empty."
  @spec min_key() :: term() | nil
  defdelegate min_key(), to: Query.Store

  @doc "Returns the largest stored key, or `nil` when empty."
  @spec max_key() :: term() | nil
  defdelegate max_key(), to: Query.Store

  @doc """
  Returns `true` when the store is empty (no keys).
  """
  @spec empty?() :: boolean()
  def empty?, do: Query.Store.count() == 0

  # Validates the requested consistency level, if any was provided. Accepts both
  # atoms and strings (e.g. `"eventual"` from an HTTP query parameter) via a
  # safe parse that never creates new atoms.
  defp validate_consistency(opts) do
    level = Keyword.get(opts, :consistency, ConsistencyLevel.default())

    case ConsistencyLevel.parse(level) do
      {:ok, _level} -> :ok
      {:error, _reason} -> {:error, {:invalid_consistency, level}}
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
    keys =
      Enum.flat_map(operations, fn
        {:write, key, _value} -> [key]
        {:delete, key} -> [key]
        _ -> []
      end)

    Query.Cache.invalidate_many(keys)
  end
end
