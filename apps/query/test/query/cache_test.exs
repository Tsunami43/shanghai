defmodule Query.CacheTest do
  @moduledoc """
  Tests the read-through cache both directly and through the public `Query`
  API (cache/store consistency across writes, deletes and transactions).
  """

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  describe "cache unit behaviour" do
    test "miss, then hit after put" do
      assert :miss = Query.Cache.get("c:1")
      :ok = Query.Cache.put("c:1", "v")
      assert {:ok, "v"} = Query.Cache.get("c:1")
    end

    test "size/0 reflects the number of cached entries" do
      assert Query.Cache.size() == 0
      :ok = Query.Cache.put("s:1", 1)
      :ok = Query.Cache.put("s:2", 2)
      assert Query.Cache.size() == 2
    end

    test "invalidate removes an entry synchronously" do
      :ok = Query.Cache.put("c:2", "v")
      :ok = Query.Cache.invalidate("c:2")
      assert :miss = Query.Cache.get("c:2")
    end

    test "invalidate_many removes several entries in one call" do
      :ok = Query.Cache.put("m:1", 1)
      :ok = Query.Cache.put("m:2", 2)
      :ok = Query.Cache.put("m:3", 3)

      :ok = Query.Cache.invalidate_many(["m:1", "m:3"])

      assert :miss = Query.Cache.get("m:1")
      assert {:ok, 2} = Query.Cache.get("m:2")
      assert :miss = Query.Cache.get("m:3")
    end

    test "stats track hits, misses and hit ratio" do
      assert :miss = Query.Cache.get("c:stat")
      :ok = Query.Cache.put("c:stat", "v")
      assert {:ok, "v"} = Query.Cache.get("c:stat")
      assert {:ok, "v"} = Query.Cache.get("c:stat")

      {:ok, stats} = Query.Cache.stats()
      assert stats.hits == 2
      assert stats.misses == 1
      assert_in_delta stats.hit_ratio, 2 / 3, 1.0e-9
      assert Map.has_key?(stats, :ttl_ms)
    end

    test "evicts oldest entries beyond max_size (FIFO)" do
      uniq = :erlang.unique_integer([:positive])

      cache =
        start_supervised!(
          {Query.Cache,
           name: :"cache_bounded_#{uniq}",
           table: :"qc_bounded_#{uniq}",
           lru: :"qc_bounded_lru_#{uniq}",
           max_size: 3}
        )

      for i <- 1..5, do: :ok = GenServer.call(cache, {:put, "k#{i}", i})

      {:ok, stats} = GenServer.call(cache, :stats)
      assert stats.size == 3

      # The three most-recent keys survive; the two oldest are evicted.
      assert GenServer.call(cache, {:get, "k1"}) == :miss
      assert GenServer.call(cache, {:get, "k2"}) == :miss
      assert GenServer.call(cache, {:get, "k5"}) == {:ok, 5}
    end

    test "entries expire after their TTL" do
      uniq = :erlang.unique_integer([:positive])

      cache =
        start_supervised!(
          {Query.Cache,
           name: :"cache_ttl_#{uniq}",
           table: :"qc_ttl_#{uniq}",
           lru: :"qc_ttl_lru_#{uniq}",
           ttl_ms: 20}
        )

      :ok = GenServer.call(cache, {:put, "k", "v"})
      assert GenServer.call(cache, {:get, "k"}) == {:ok, "v"}

      Process.sleep(40)
      assert GenServer.call(cache, {:get, "k"}) == :miss
    end
  end

  describe "read-through via Query" do
    test "second read is served from cache" do
      {:ok, :written} = Query.write("k", "v1")
      assert {:ok, "v1"} = Query.read("k")
      assert {:ok, %{size: size}} = Query.Cache.stats()
      assert size >= 1
    end

    test "write invalidates the cache (no stale read)" do
      {:ok, :written} = Query.write("k", "v1")
      {:ok, "v1"} = Query.read("k")

      {:ok, :written} = Query.write("k", "v2")
      assert {:ok, "v2"} = Query.read("k")
    end

    test "delete invalidates the cache" do
      {:ok, :written} = Query.write("k", "v")
      {:ok, "v"} = Query.read("k")

      {:ok, :deleted} = Query.delete("k")
      assert {:error, :not_found} = Query.read("k")
    end

    test "transaction invalidates all touched keys" do
      {:ok, :written} = Query.write("a", 1)
      {:ok, 1} = Query.read("a")

      {:ok, :committed} = Query.transact([{:write, "a", 2}, {:write, "b", 3}])
      assert {:ok, 2} = Query.read("a")
      assert {:ok, 3} = Query.read("b")
    end
  end
end
