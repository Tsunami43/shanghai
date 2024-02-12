defmodule Query.Cache do
  @moduledoc """
  Bounded, TTL-aware read cache for the query layer.

  `Query.read/2` consults this cache before hitting `Query.Store`; successful
  reads are cached and every mutation (`write`/`delete`/`transact`) invalidates
  the affected keys, keeping the cache consistent with the store on a single
  node (writes are serialized through `Query.Store`).

  ## Design

  - Values live in an ETS `:set` (`key -> {value, expires_at, seq}`) that
    `get/1` reads directly for low latency.
  - Insertion order is tracked in an ETS `:ordered_set` (`seq -> key`) so the
    oldest entry can be evicted in O(log n) when the cache is over capacity
    (FIFO eviction).
  - Entries past their TTL are treated as misses (and lazily removed).

  ## Options

  - `:max_size` - maximum number of cached keys (default: 10_000)
  - `:ttl_ms` - entry time-to-live in ms, or `nil` for no expiry (default: nil)
  """

  use GenServer

  @table :query_cache
  @lru :query_cache_lru
  @counters :query_cache_counters

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Looks up `key`. Returns `{:ok, value}` on a live hit, otherwise `:miss`."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _seq}] ->
        if expired?(expires_at) do
          GenServer.cast(__MODULE__, {:expire, key})
          bump(:misses)
          :miss
        else
          bump(:hits)
          {:ok, value}
        end

      [] ->
        bump(:misses)
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Caches `value` under `key`.

  Synchronous so the entry is visible immediately. Only the (slower) cache-miss
  read path calls this; cache hits read ETS directly without touching the process.
  """
  @spec put(term(), term()) :: :ok
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc """
  Removes `key` from the cache.

  Synchronous: once it returns, a direct `get/1` will miss. This is what keeps
  a write-then-read consistent, since mutations invalidate before returning.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key), do: GenServer.call(__MODULE__, {:invalidate, key})

  @doc """
  Removes several keys from the cache in one call. Synchronous — once it returns,
  a direct `get/1` for any of the keys will miss. More efficient than repeated
  `invalidate/1` for bulk mutations.
  """
  @spec invalidate_many([term()]) :: :ok
  def invalidate_many(keys) when is_list(keys),
    do: GenServer.call(__MODULE__, {:invalidate_many, keys})

  @doc "Removes every cached entry."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Returns cache statistics."
  @spec stats() :: {:ok, map()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Returns the cache hit ratio (0.0..1.0) directly, or `0.0` when there have been
  no lookups yet. A convenience over reading it out of `stats/0`.
  """
  @spec hit_ratio() :: float()
  def hit_ratio do
    {:ok, stats} = stats()
    stats.hit_ratio
  end

  @doc "Returns the number of entries currently cached."
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @doc """
  Returns `true` when `key` has a live (non-expired) cache entry. A read-only
  probe: unlike `get/1`, it does not affect the hit/miss counters.
  """
  @spec cached?(term()) :: boolean()
  def cached?(key) do
    case :ets.lookup(@table, key) do
      [{^key, _value, expires_at, _seq}] -> not expired?(expires_at)
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @table)
    lru_name = Keyword.get(opts, :lru, @lru)
    counters_name = Keyword.get(opts, :counters, @counters)
    table = :ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])
    lru = :ets.new(lru_name, [:named_table, :ordered_set, :protected])
    # Public so the caller-side get/1 can bump hit/miss counters atomically
    # without a round-trip through this process. Reuse an existing table so
    # embedded instances that share a counters name do not clash.
    counters = ensure_counters(counters_name)

    state = %{
      table: table,
      lru: lru,
      counters: counters,
      max_size: Keyword.get(opts, :max_size, 10_000),
      ttl_ms: Keyword.get(opts, :ttl_ms, nil),
      seq: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:expire, key}, state) do
    drop_lru_entry(state, key)
    :ets.delete(state.table, key)
    {:noreply, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    drop_lru_entry(state, key)

    seq = state.seq + 1
    expires_at = expires_at(state.ttl_ms)
    :ets.insert(state.table, {key, value, expires_at, seq})
    :ets.insert(state.lru, {seq, key})

    state = evict_if_needed(%{state | seq: seq})
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    reply =
      case :ets.lookup(state.table, key) do
        [{^key, value, expires_at, _seq}] ->
          if expired?(expires_at), do: :miss, else: {:ok, value}

        [] ->
          :miss
      end

    {:reply, reply, state}
  end

  def handle_call({:invalidate, key}, _from, state) do
    drop_lru_entry(state, key)
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call({:invalidate_many, keys}, _from, state) do
    Enum.each(keys, fn key ->
      drop_lru_entry(state, key)
      :ets.delete(state.table, key)
    end)

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    :ets.delete_all_objects(state.lru)
    :ets.insert(state.counters, [{:hits, 0}, {:misses, 0}])
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    hits = counter_value(state.counters, :hits)
    misses = counter_value(state.counters, :misses)
    total = hits + misses

    stats = %{
      size: :ets.info(state.table, :size),
      max_size: state.max_size,
      ttl_ms: state.ttl_ms,
      hits: hits,
      misses: misses,
      hit_ratio: if(total > 0, do: hits / total, else: 0.0)
    }

    {:reply, {:ok, stats}, state}
  end

  ## Helpers

  defp drop_lru_entry(state, key) do
    case :ets.lookup(state.table, key) do
      [{^key, _value, _expires_at, seq}] -> :ets.delete(state.lru, seq)
      [] -> :ok
    end
  end

  defp evict_if_needed(state) do
    if :ets.info(state.table, :size) > state.max_size do
      case :ets.first(state.lru) do
        :"$end_of_table" ->
          state

        oldest_seq ->
          [{^oldest_seq, key}] = :ets.lookup(state.lru, oldest_seq)
          :ets.delete(state.lru, oldest_seq)
          :ets.delete(state.table, key)
          evict_if_needed(state)
      end
    else
      state
    end
  end

  defp ensure_counters(name) do
    case :ets.whereis(name) do
      :undefined ->
        table = :ets.new(name, [:named_table, :set, :public])
        :ets.insert(table, [{:hits, 0}, {:misses, 0}])
        table

      _ref ->
        name
    end
  end

  # Atomic, caller-side counter bump; a no-op if the counters table is absent.
  defp bump(counter) do
    :ets.update_counter(@counters, counter, 1)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp counter_value(counters, counter) do
    case :ets.lookup(counters, counter) do
      [{^counter, value}] -> value
      [] -> 0
    end
  end

  defp expires_at(nil), do: nil
  defp expires_at(ttl_ms), do: System.monotonic_time(:millisecond) + ttl_ms

  defp expired?(nil), do: false
  defp expired?(expires_at), do: System.monotonic_time(:millisecond) >= expires_at
end
