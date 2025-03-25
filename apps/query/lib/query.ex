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
  Atomically removes and returns the first element of the list stored at `key`
  (a queue dequeue). Returns `{:ok, element}`, or `{:ok, nil}` when the key is
  absent, empty, or does not hold a list.
  """
  @spec pop_first(String.t()) :: {:ok, term()} | {:error, term()}
  def pop_first(key) do
    case read(key) do
      {:ok, [_head | _tail]} -> get_and_update(key, fn [head | tail] -> {head, tail} end)
      _ -> {:ok, nil}
    end
  end

  @doc """
  Atomically removes and returns the last element of the list stored at `key`
  (a stack pop). Returns `{:ok, element}`, or `{:ok, nil}` when the key is
  absent, empty, or does not hold a list.
  """
  @spec pop_last(String.t()) :: {:ok, term()} | {:error, term()}
  def pop_last(key) do
    case read(key) do
      {:ok, list} when is_list(list) and list != [] ->
        get_and_update(key, fn current ->
          {List.last(current), Enum.drop(current, -1)}
        end)

      _ ->
        {:ok, nil}
    end
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
  Atomically merges `fields` into the map stored at `key`, creating an empty map
  when the key is absent. Keys in `fields` take precedence. Returns
  `{:ok, new_map}`.
  """
  @spec merge_fields(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def merge_fields(key, fields) when is_map(fields) do
    update(key, %{}, fn map -> Map.merge(map, fields) end)
  end

  @doc """
  Atomically sets a nested value in the map stored at `key`, following `path` (a
  non-empty list of keys) and creating intermediate maps as needed. A stored
  non-map value is replaced with a fresh map. Returns `{:ok, new_map}`.

  ## Examples

      iex> Query.put_path("cfg", [:db, :host], "localhost")
      {:ok, %{db: %{host: "localhost"}}}
  """
  @spec put_path(String.t(), [term(), ...], term()) :: {:ok, map()} | {:error, term()}
  def put_path(key, [_ | _] = path, value) do
    update(key, %{}, fn map ->
      base = if is_map(map), do: map, else: %{}
      deep_put(base, path, value)
    end)
  end

  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    child = Map.get(map, key)
    child = if is_map(child), do: child, else: %{}
    Map.put(map, key, deep_put(child, rest, value))
  end

  @doc """
  Atomically updates the nested value at `path` in the map stored at `key` by
  applying `fun` to the current value (or `nil` when the path is unset),
  creating intermediate maps as needed. Returns `{:ok, new_map}`.

  ## Examples

      iex> Query.put_path("cfg", [:db, :conns], 1)
      iex> Query.update_path("cfg", [:db, :conns], &(&1 + 1))
      {:ok, %{db: %{conns: 2}}}
  """
  @spec update_path(String.t(), [term(), ...], (term() -> term())) ::
          {:ok, map()} | {:error, term()}
  def update_path(key, [_ | _] = path, fun) when is_function(fun, 1) do
    update(key, %{}, fn map ->
      base = if is_map(map), do: map, else: %{}

      current =
        case fetch_path(base, path) do
          {:ok, value} -> value
          :error -> nil
        end

      deep_put(base, path, fun.(current))
    end)
  end

  @doc """
  Atomically removes a nested key from the map stored at `key`, following `path`
  (a non-empty list of keys). A no-op when the key is absent, the value is not a
  map, or the path does not resolve. Returns `{:ok, new_map}`.
  """
  @spec delete_path(String.t(), [term(), ...]) :: {:ok, map()} | {:error, term()}
  def delete_path(key, [_ | _] = path) do
    update(key, %{}, fn map ->
      if is_map(map), do: deep_delete(map, path), else: map
    end)
  end

  defp deep_delete(map, [key]), do: Map.delete(map, key)

  defp deep_delete(map, [key | rest]) do
    case Map.get(map, key) do
      child when is_map(child) -> Map.put(map, key, deep_delete(child, rest))
      _ -> map
    end
  end

  @doc """
  Atomically renames `from` to `to` within the map stored at `key`, preserving
  the value. A no-op when the key is absent, holds a non-map, or lacks `from`.
  Returns `{:ok, new_map}`.
  """
  @spec rename_field(String.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def rename_field(key, from, to) do
    update(key, %{}, fn map ->
      case map do
        %{^from => value} -> map |> Map.delete(from) |> Map.put(to, value)
        _ -> map
      end
    end)
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
  Atomically raises the numeric value at `key` to `value` when `value` is
  greater (a monotonic high-water mark). Seeds `value` when the key is absent.
  Returns `{:ok, stored_value}`.
  """
  @spec bump_max(String.t(), number()) :: {:ok, number()} | {:error, term()}
  def bump_max(key, value) when is_number(value) do
    update(key, value, fn
      current when is_number(current) -> max(current, value)
      _ -> value
    end)
  end

  @doc """
  Atomically lowers the numeric value at `key` to `value` when `value` is
  smaller (a monotonic low-water mark). Seeds `value` when the key is absent.
  Returns `{:ok, stored_value}`.
  """
  @spec bump_min(String.t(), number()) :: {:ok, number()} | {:error, term()}
  def bump_min(key, value) when is_number(value) do
    update(key, value, fn
      current when is_number(current) -> min(current, value)
      _ -> value
    end)
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
  Reads a nested value from the map stored at `key` following `path` (a list of
  keys), returning `default` when the key is absent, the value is not a map, or
  the path does not resolve.

  ## Examples

      iex> Query.write("cfg", %{db: %{host: "localhost"}})
      iex> Query.get_path("cfg", [:db, :host])
      "localhost"
  """
  @spec get_path(String.t(), [term()], term()) :: term()
  def get_path(key, path, default \\ nil) when is_list(path) do
    case read(key) do
      {:ok, map} when is_map(map) ->
        case fetch_path(map, path) do
          {:ok, value} -> value
          :error -> default
        end

      _ ->
        default
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  @doc """
  Returns `true` when the nested `path` resolves to a value in the map stored at
  `key`. A read-only accessor.
  """
  @spec has_path?(String.t(), [term()]) :: boolean()
  def has_path?(key, path) when is_list(path) do
    case read(key) do
      {:ok, map} when is_map(map) -> match?({:ok, _}, fetch_path(map, path))
      _ -> false
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
  Returns the number of fields in the map stored at `key`, or `0` when the key
  is absent or does not hold a map. A read-only accessor.
  """
  @spec field_count(String.t()) :: non_neg_integer()
  def field_count(key) do
    case read(key) do
      {:ok, map} when is_map(map) -> map_size(map)
      _ -> 0
    end
  end

  @doc """
  Returns the sorted field keys of the map stored at `key`, or `[]` when the key
  is absent or does not hold a map. A read-only accessor.
  """
  @spec fields(String.t()) :: [term()]
  def fields(key) do
    case read(key) do
      {:ok, map} when is_map(map) -> map |> Map.keys() |> Enum.sort()
      _ -> []
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
  Returns the subset of `keys` that are present in the store, preserving the
  input order. The complement of `missing/1`.
  """
  @spec present([String.t()]) :: [String.t()]
  def present(keys) when is_list(keys) do
    Enum.filter(keys, &Query.Store.exists?/1)
  end

  @doc """
  Warms the read cache for `keys` by reading each through the cache, populating
  it for keys that exist. Returns the number of keys that were found and cached.
  Useful ahead of a read-heavy burst.
  """
  @spec warm([String.t()]) :: non_neg_integer()
  def warm(keys) when is_list(keys) do
    Enum.count(keys, fn key -> match?({:ok, _}, read(key)) end)
  end

  @doc """
  Returns `true` when every key in `keys` exists. An empty list is vacuously
  `true`. A cheap membership check that avoids fetching values.
  """
  @spec exists_all?([String.t()]) :: boolean()
  def exists_all?(keys) when is_list(keys) do
    Enum.all?(keys, &Query.Store.exists?/1)
  end

  @doc """
  Returns `true` when at least one key in `keys` exists. An empty list is `false`.
  """
  @spec exists_any?([String.t()]) :: boolean()
  def exists_any?(keys) when is_list(keys) do
    Enum.any?(keys, &Query.Store.exists?/1)
  end

  @doc """
  Returns the number of keys in `keys` that exist. A cheap counterpart to
  `mget/1` when only the count matters.
  """
  @spec count_existing([String.t()]) :: non_neg_integer()
  def count_existing(keys) when is_list(keys) do
    Enum.count(keys, &Query.Store.exists?/1)
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
  Returns a compact one-call summary of the query layer: the live key count,
  whether the store is durable, and the cache size and hit ratio.

  ## Examples

      iex> summary = Query.summary()
      iex> is_integer(summary.keys) and is_boolean(summary.durable)
      true
  """
  @spec summary() :: %{
          keys: non_neg_integer(),
          durable: boolean(),
          cache_size: non_neg_integer(),
          cache_hit_ratio: float()
        }
  def summary do
    {:ok, store} = Query.Store.info()
    {:ok, cache} = Query.Cache.stats()

    %{
      keys: Map.get(store, :size, 0),
      durable: Map.get(store, :durable, false),
      cache_size: Map.get(cache, :size, 0),
      cache_hit_ratio: Map.get(cache, :hit_ratio, 0.0)
    }
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

  @doc """
  Returns `true` when no key starts with `prefix` — the whole namespace is empty.
  """
  @spec prefix_empty?(binary()) :: boolean()
  def prefix_empty?(prefix) when is_binary(prefix), do: count_prefix(prefix) == 0

  @doc """
  Returns `true` when exactly one key starts with `prefix`.
  """
  @spec unique_prefix?(binary()) :: boolean()
  def unique_prefix?(prefix) when is_binary(prefix), do: count_prefix(prefix) == 1

  @doc """
  Returns the distinct prefixes obtained by splitting each key on `separator`
  and taking the first segment, sorted. Useful for discovering key namespaces.
  """
  @spec namespaces(binary()) :: [binary()]
  def namespaces(separator \\ ":") when is_binary(separator) do
    keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn key -> key |> String.split(separator, parts: 2) |> hd() end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns a map of `namespace => key_count` — how many keys fall under each
  first-segment namespace (split on `separator`). Useful for a quick key-space
  distribution overview.
  """
  @spec namespace_counts(binary()) :: %{optional(binary()) => non_neg_integer()}
  def namespace_counts(separator \\ ":") when is_binary(separator) do
    keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies_by(fn key -> key |> String.split(separator, parts: 2) |> hd() end)
  end

  @doc "Returns `true` when at least one key starts with `prefix`."
  @spec any_prefix?(binary()) :: boolean()
  defdelegate any_prefix?(prefix), to: Query.Store

  @doc """
  Deletes every key that starts with `prefix` and returns the pairs that were
  removed, sorted by key. A scan followed by an atomic prefix delete, so a
  concurrent write to the same namespace may be deleted without being returned.
  """
  @spec drain_prefix(binary()) :: {:ok, [{binary(), term()}]} | {:error, term()}
  def drain_prefix(prefix) when is_binary(prefix) do
    pairs = Query.Store.scan(prefix, [])

    case delete_prefix(prefix) do
      {:ok, _deleted} -> {:ok, pairs}
      other -> other
    end
  end

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

  @doc """
  Returns the stored keys, in key order, that share the common prefix up to the
  first occurrence of `separator`. A read-only view for namespace inspection.
  """
  @spec keys_in_namespace(binary(), binary()) :: [binary()]
  def keys_in_namespace(namespace, separator \\ ":") when is_binary(namespace) do
    prefix = namespace <> separator

    keys()
    |> Enum.filter(fn key -> is_binary(key) and String.starts_with?(key, prefix) end)
    |> Enum.sort()
  end

  @doc """
  Returns the number of keys that satisfy `fun`. A read-only key-predicate count
  over the whole store.
  """
  @spec count_keys((term() -> as_boolean(term()))) :: non_neg_integer()
  def count_keys(fun) when is_function(fun, 1) do
    Enum.count(keys(), fun)
  end

  @doc """
  Returns `true` when every key satisfies `fun`. Vacuously `true` for an empty
  store. A read-only key-predicate check over the whole store.
  """
  @spec all_keys?((term() -> as_boolean(term()))) :: boolean()
  def all_keys?(fun) when is_function(fun, 1) do
    Enum.all?(keys(), fun)
  end

  @doc """
  Returns the keys that satisfy `fun`, sorted. A read-only key-predicate scan
  over the whole store.
  """
  @spec keys_matching((term() -> as_boolean(term()))) :: [term()]
  def keys_matching(fun) when is_function(fun, 1) do
    keys() |> Enum.filter(fun) |> Enum.sort()
  end

  @doc "Returns the keys that start with `prefix`, sorted."
  @spec keys_prefix(binary()) :: [binary()]
  defdelegate keys_prefix(prefix), to: Query.Store

  @doc "Returns the values whose key starts with `prefix`, in key order."
  @spec values_prefix(binary()) :: [term()]
  defdelegate values_prefix(prefix), to: Query.Store

  @doc """
  Returns the `{key, value}` pairs whose key starts with `prefix` as a map.
  Convenience over `scan/1` when a map is more useful than an ordered list.
  """
  @spec map_prefix(binary()) :: %{optional(binary()) => term()}
  def map_prefix(prefix) when is_binary(prefix) do
    prefix |> Query.Store.scan([]) |> Map.new()
  end

  @doc "Returns the keys within the inclusive range `[low, high]`, sorted."
  @spec keys_between(term(), term()) :: [term()]
  defdelegate keys_between(low, high), to: Query.Store

  @doc "Returns the number of keys within the inclusive range `[low, high]`."
  @spec count_between(term(), term()) :: non_neg_integer()
  defdelegate count_between(low, high), to: Query.Store

  @doc "Returns the `{key, value}` pairs within the inclusive range `[low, high]`, sorted."
  @spec pairs_between(term(), term()) :: [{term(), term()}]
  defdelegate pairs_between(low, high), to: Query.Store

  @doc "Returns the number of stored keys."
  @spec count() :: non_neg_integer()
  defdelegate count(), to: Query.Store

  @doc """
  Returns the store's keys partitioned into `{matching, rest}` by the key
  predicate `fun`, each sorted. Scans the whole store.
  """
  @spec partition_keys((term() -> as_boolean(term()))) :: {[term()], [term()]}
  def partition_keys(fun) when is_function(fun, 1) do
    {matching, rest} = Enum.split_with(keys(), fun)
    {Enum.sort(matching), Enum.sort(rest)}
  end

  @doc """
  Returns the store as a list of `%{key: k, value: v}` maps, sorted by key. A
  serialization-friendly view (e.g. for JSON export).
  """
  @spec to_entries() :: [%{key: term(), value: term()}]
  def to_entries do
    for {key, value} <- to_list(), do: %{key: key, value: value}
  end

  @doc """
  Returns the number of distinct values stored. Scans the whole store.
  """
  @spec distinct_value_count() :: non_neg_integer()
  def distinct_value_count do
    values() |> Enum.uniq() |> length()
  end

  @doc """
  Returns the store's `{key, value}` pairs whose value equals `value`, sorted by
  key. Scans the whole store.
  """
  @spec pairs_with_value(term()) :: [{term(), term()}]
  def pairs_with_value(value) do
    Enum.filter(to_list(), fn {_key, v} -> v == value end)
  end

  @doc """
  Returns the store's `{key, value}` pairs sorted by a value-derived key via
  `fun`. A read-only view; ties keep key order. Scans the whole store.
  """
  @spec sort_by_value((term() -> term())) :: [{term(), term()}]
  def sort_by_value(fun) when is_function(fun, 1) do
    Enum.sort_by(to_list(), fn {_key, value} -> fun.(value) end)
  end

  @doc """
  Returns a map of `key => transformed_value`, applying `fun` to every stored
  value. A read-only projection preserving keys. Scans the whole store.
  """
  @spec transform_values((term() -> term())) :: %{optional(term()) => term()}
  def transform_values(fun) when is_function(fun, 1) do
    Map.new(to_list(), fn {key, value} -> {key, fun.(value)} end)
  end

  @doc """
  Returns the store's `{key, value}` pairs converted via `fun`, in key order.
  A read-only projection over both key and value. Scans the whole store.
  """
  @spec map(({term(), term()} -> term())) :: [term()]
  def map(fun) when is_function(fun, 1) do
    Enum.map(to_list(), fun)
  end

  @doc """
  Applies `fun` to every `{key, value}` pair in key order, for its side effects,
  and returns `:ok`. Scans the whole store.
  """
  @spec each(({term(), term()} -> any())) :: :ok
  def each(fun) when is_function(fun, 1) do
    Enum.each(to_list(), fun)
  end

  @doc """
  Returns `true` when every stored `{key, value}` pair satisfies `fun`. Vacuously
  `true` for an empty store. Scans the whole store.
  """
  @spec all?(({term(), term()} -> as_boolean(term()))) :: boolean()
  def all?(fun) when is_function(fun, 1) do
    Enum.all?(to_list(), fun)
  end

  @doc """
  Returns `true` when at least one stored `{key, value}` pair satisfies `fun`.
  `false` for an empty store. Scans the whole store.
  """
  @spec exists_pair?(({term(), term()} -> as_boolean(term()))) :: boolean()
  def exists_pair?(fun) when is_function(fun, 1) do
    Enum.any?(to_list(), fun)
  end

  @doc "Returns the entire store as a map of `key => value`."
  @spec to_map() :: %{optional(term()) => term()}
  defdelegate to_map(), to: Query.Store

  @doc "Returns the entire store as a list of `{key, value}` pairs, sorted by key."
  @spec to_list() :: [{term(), term()}]
  defdelegate to_list(), to: Query.Store

  @doc "Returns every stored value, in key order."
  @spec values() :: [term()]
  defdelegate values(), to: Query.Store

  @doc """
  Returns the number of stored values that satisfy `fun`. A read-only
  value-predicate count over the whole store.
  """
  @spec count_values((term() -> as_boolean(term()))) :: non_neg_integer()
  def count_values(fun) when is_function(fun, 1) do
    Enum.count(values(), fun)
  end

  @doc """
  Returns the minimum and maximum keys as `{min, max}`, or `nil` when the store
  is empty. A cheap key-range probe.
  """
  @spec key_range() :: {term(), term()} | nil
  def key_range do
    case min_key() do
      nil -> nil
      min -> {min, max_key()}
    end
  end

  @doc """
  Returns the store's values in descending key order.
  """
  @spec values_desc() :: [term()]
  def values_desc do
    to_list() |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns `true` when at least one stored value equals `value`. Scans the whole
  store.
  """
  @spec has_value?(term()) :: boolean()
  def has_value?(value), do: Enum.any?(values(), &(&1 == value))

  @doc """
  Returns the keys that hold `value`, sorted. Scans the whole store.
  """
  @spec keys_for_value(term()) :: [term()]
  def keys_for_value(value) do
    for({key, v} <- to_list(), v == value, do: key)
  end

  @doc """
  Returns the store's `{key, value}` pairs grouped by the result of applying
  `fun` to each value, as `%{group => [{key, value}]}`. Each group's list is
  sorted by key. Scans the whole store.
  """
  @spec group_by((term() -> term())) :: %{optional(term()) => [{term(), term()}]}
  def group_by(fun) when is_function(fun, 1) do
    to_list()
    |> Enum.group_by(fn {_key, value} -> fun.(value) end)
    |> Map.new(fn {group, pairs} -> {group, Enum.sort_by(pairs, &elem(&1, 0))} end)
  end

  @doc """
  Returns a map of `value => key_count` — how many keys hold each distinct
  value. Scans the whole store.
  """
  @spec value_counts() :: %{optional(term()) => non_neg_integer()}
  def value_counts do
    Enum.frequencies(values())
  end

  @doc """
  Returns the distinct stored values, sorted. Scans the whole store — useful for
  discovering the set of values in a small key space.
  """
  @spec distinct_values() :: [term()]
  def distinct_values, do: values() |> Enum.uniq() |> Enum.sort()

  @doc """
  Returns the `{key, value}` pairs for which `fun` returns a truthy value,
  sorted by key. Scans the whole store — use `scan/2` or `pairs_between/2` when a
  key range suffices.
  """
  @spec filter(({term(), term()} -> as_boolean(term()))) :: [{term(), term()}]
  def filter(fun) when is_function(fun, 1) do
    Enum.filter(to_list(), fun)
  end

  @doc """
  Returns the number of `{key, value}` pairs for which `fun` returns a truthy
  value. Scans the whole store.
  """
  @spec count_where(({term(), term()} -> as_boolean(term()))) :: non_neg_integer()
  def count_where(fun) when is_function(fun, 1) do
    Enum.count(to_list(), fun)
  end

  @doc """
  Partitions the store's `{key, value}` pairs into `{matching, rest}` by the
  predicate `fun`, each list sorted by key. Scans the whole store.
  """
  @spec partition(({term(), term()} -> as_boolean(term()))) ::
          {[{term(), term()}], [{term(), term()}]}
  def partition(fun) when is_function(fun, 1) do
    Enum.split_with(to_list(), fun)
  end

  @doc """
  Returns the first `{key, value}` pair (in key order) for which `fun` returns a
  truthy value, or `nil` when none match. Scans the whole store.
  """
  @spec find(({term(), term()} -> as_boolean(term()))) :: {term(), term()} | nil
  def find(fun) when is_function(fun, 1) do
    Enum.find(to_list(), fun)
  end

  @doc """
  Returns the keys whose value satisfies `fun`, sorted. Scans the whole store.
  """
  @spec keys_where((term() -> as_boolean(term()))) :: [term()]
  def keys_where(fun) when is_function(fun, 1) do
    for {key, value} <- to_list(), fun.(value), do: key
  end

  @doc """
  Applies `fun` to every stored value and returns the results in key order.
  Scans the whole store — a read-only projection helper.
  """
  @spec map_values((term() -> term())) :: [term()]
  def map_values(fun) when is_function(fun, 1) do
    for {_key, value} <- to_list(), do: fun.(value)
  end

  @doc """
  Folds `fun` over every `{key, value}` pair in key order, starting from `acc`.
  Scans the whole store — a read-only aggregation helper.

  ## Examples

      iex> Query.mset(%{"a" => 1, "b" => 2, "c" => 3})
      iex> Query.reduce(0, fn {_k, v}, acc -> acc + v end)
      6
  """
  @spec reduce(acc, ({term(), term()}, acc -> acc)) :: acc when acc: var
  def reduce(acc, fun) when is_function(fun, 2) do
    Enum.reduce(to_list(), acc, fun)
  end

  @doc """
  Returns the sum of all numeric values in the store, ignoring non-numeric ones.
  Scans the whole store.
  """
  @spec sum_values() :: number()
  def sum_values do
    reduce(0, fn
      {_key, value}, acc when is_number(value) -> acc + value
      {_key, _value}, acc -> acc
    end)
  end

  @doc """
  Returns the sum of the numeric values for `keys` (missing or non-numeric
  values contribute `0`).
  """
  @spec sum_of([String.t()]) :: number()
  def sum_of(keys) when is_list(keys) do
    Enum.reduce(keys, 0, fn key, acc ->
      case get(key) do
        value when is_number(value) -> acc + value
        _ -> acc
      end
    end)
  end

  @doc """
  Returns the number of stored values that are numeric. Scans the whole store.
  """
  @spec numeric_count() :: non_neg_integer()
  def numeric_count do
    Enum.count(values(), &is_number/1)
  end

  @doc """
  Returns the average of all numeric values in the store, ignoring non-numeric
  ones. Returns `0.0` when there are no numeric values. Scans the whole store.
  """
  @spec avg_values() :: float()
  def avg_values do
    {sum, count} =
      reduce({0, 0}, fn
        {_key, value}, {sum, count} when is_number(value) -> {sum + value, count + 1}
        {_key, _value}, acc -> acc
      end)

    if count > 0, do: sum / count, else: 0.0
  end

  @doc """
  Returns the largest numeric value in the store, or `nil` when there are no
  numeric values. Scans the whole store.
  """
  @spec max_value() :: number() | nil
  def max_value, do: numeric_values() |> extreme(&Enum.max/1)

  @doc """
  Returns the smallest numeric value in the store, or `nil` when there are no
  numeric values. Scans the whole store.
  """
  @spec min_value() :: number() | nil
  def min_value, do: numeric_values() |> extreme(&Enum.min/1)

  defp numeric_values, do: for({_key, value} <- to_list(), is_number(value), do: value)

  @doc """
  Returns compact aggregate statistics over the store's numeric values:
  `%{count, sum, min, max, avg}`. `min`/`max` are `nil` and `avg` is `0.0` when
  there are no numeric values. Scans the whole store.
  """
  @spec value_stats() :: %{
          count: non_neg_integer(),
          sum: number(),
          min: number() | nil,
          max: number() | nil,
          avg: float()
        }
  def value_stats do
    values = numeric_values()
    count = length(values)
    sum = Enum.sum(values)

    %{
      count: count,
      sum: sum,
      min: extreme(values, &Enum.min/1),
      max: extreme(values, &Enum.max/1),
      avg: if(count > 0, do: sum / count, else: 0.0)
    }
  end

  defp extreme([], _fun), do: nil
  defp extreme(values, fun), do: fun.(values)

  @doc """
  Groups the store's keys by the result of applying `fun` to each value,
  returning a map of `group => [keys]` (each key list sorted). Scans the whole
  store.

  ## Examples

      iex> Query.mset(%{"a" => 1, "b" => 2, "c" => 3})
      iex> Query.group_keys_by(fn v -> rem(v, 2) end)
      %{0 => ["b"], 1 => ["a", "c"]}
  """
  @spec group_keys_by((term() -> term())) :: %{optional(term()) => [term()]}
  def group_keys_by(fun) when is_function(fun, 1) do
    to_list()
    |> Enum.group_by(fn {_key, value} -> fun.(value) end, fn {key, _value} -> key end)
    |> Map.new(fn {group, keys} -> {group, Enum.sort(keys)} end)
  end

  @doc "Returns the smallest stored key, or `nil` when empty."
  @spec min_key() :: term() | nil
  defdelegate min_key(), to: Query.Store

  @doc """
  Returns the stored keys in descending order. The reverse of `keys() |> sort`.
  """
  @spec keys_desc() :: [term()]
  def keys_desc, do: keys() |> Enum.sort(:desc)

  @doc "Returns the largest stored key, or `nil` when empty."
  @spec max_key() :: term() | nil
  defdelegate max_key(), to: Query.Store

  @doc """
  Returns the `{key, value}` pair with the largest numeric value, or `nil` when
  there are no numeric values. Scans the whole store.
  """
  @spec max_by_value() :: {term(), number()} | nil
  def max_by_value, do: extreme_pair(&>=/2)

  @doc """
  Returns the `{key, value}` pair with the smallest numeric value, or `nil` when
  there are no numeric values. Scans the whole store.
  """
  @spec min_by_value() :: {term(), number()} | nil
  def min_by_value, do: extreme_pair(&<=/2)

  defp extreme_pair(better?) do
    to_list()
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> case do
      [] ->
        nil

      [first | rest] ->
        Enum.reduce(rest, first, fn {_k, v} = pair, {_bk, bv} = best ->
          if better?.(v, bv), do: pair, else: best
        end)
    end
  end

  @doc """
  Returns the `{key, value}` pair at the smallest key, or `nil` when the store
  is empty.
  """
  @spec first() :: {term(), term()} | nil
  def first do
    case min_key() do
      nil -> nil
      key -> {key, get(key)}
    end
  end

  @doc """
  Returns the `{key, value}` pair at the largest key, or `nil` when the store is
  empty.
  """
  @spec last() :: {term(), term()} | nil
  def last do
    case max_key() do
      nil -> nil
      key -> {key, get(key)}
    end
  end

  @doc """
  Atomically removes and returns the `{key, value}` pair at the smallest key, or
  `{:ok, nil}` when the store is empty. Useful for ordered draining.
  """
  @spec pop_min() :: {:ok, {term(), term()} | nil} | {:error, term()}
  def pop_min do
    case min_key() do
      nil -> {:ok, nil}
      key -> pop_pair(key)
    end
  end

  @doc """
  Atomically removes and returns the `{key, value}` pair at the largest key, or
  `{:ok, nil}` when the store is empty.
  """
  @spec pop_max() :: {:ok, {term(), term()} | nil} | {:error, term()}
  def pop_max do
    case max_key() do
      nil -> {:ok, nil}
      key -> pop_pair(key)
    end
  end

  defp pop_pair(key) do
    case take(key) do
      {:ok, value} -> {:ok, {key, value}}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  @doc """
  Returns `true` when the store is empty (no keys).
  """
  @spec empty?() :: boolean()
  def empty?, do: Query.Store.count() == 0

  @doc """
  Returns `true` when the store holds exactly one key.
  """
  @spec single?() :: boolean()
  def single?, do: Query.Store.count() == 1

  @doc """
  Returns the single stored `{key, value}` pair, or `nil` unless the store holds
  exactly one key.
  """
  @spec only() :: {term(), term()} | nil
  def only do
    case to_list() do
      [pair] -> pair
      _ -> nil
    end
  end

  @doc """
  Returns `true` when the store has at least one key. The complement of
  `empty?/0`.
  """
  @spec any?() :: boolean()
  def any?, do: Query.Store.count() > 0

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
