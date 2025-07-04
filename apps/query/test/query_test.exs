defmodule QueryTest do
  use ExUnit.Case, async: false

  setup do
    # The store is started by Query.Application; reset it between tests so each
    # test observes a clean key space.
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  describe "write/read" do
    test "reads back a written value" do
      assert {:ok, :written} = Query.write("user:1", %{name: "Alice"})
      assert {:ok, %{name: "Alice"}} = Query.read("user:1")
    end

    test "overwrites an existing key" do
      assert {:ok, :written} = Query.write("k", "v1")
      assert {:ok, :written} = Query.write("k", "v2")
      assert {:ok, "v2"} = Query.read("k")
    end

    test "reading a missing key returns :not_found" do
      assert {:error, :not_found} = Query.read("does-not-exist")
    end

    test "rejects an invalid consistency level" do
      assert {:error, {:invalid_consistency, :nonsense}} =
               Query.write("k", "v", consistency: :nonsense)

      assert {:error, {:invalid_consistency, :nonsense}} =
               Query.read("k", consistency: :nonsense)
    end

    test "accepts a consistency level given as a string" do
      assert {:ok, :written} = Query.write("k", "v", consistency: "eventual")
      assert {:ok, "v"} = Query.read("k", consistency: "strong")

      assert {:error, {:invalid_consistency, "nope"}} =
               Query.read("k", consistency: "nope")
    end
  end

  describe "delete/2" do
    test "removes a key" do
      assert {:ok, :written} = Query.write("k", "v")
      assert {:ok, :deleted} = Query.delete("k")
      assert {:error, :not_found} = Query.read("k")
    end

    test "is idempotent for a missing key" do
      assert {:ok, :deleted} = Query.delete("never-existed")
    end
  end

  describe "transact/1" do
    test "applies all writes atomically" do
      ops = [
        {:write, "account:1", %{balance: 100}},
        {:write, "account:2", %{balance: 50}}
      ]

      assert {:ok, :committed} = Query.transact(ops)
      assert {:ok, %{balance: 100}} = Query.read("account:1")
      assert {:ok, %{balance: 50}} = Query.read("account:2")
    end

    test "supports deletes inside a transaction" do
      assert {:ok, :written} = Query.write("k", "v")
      assert {:ok, :committed} = Query.transact([{:delete, "k"}, {:write, "k2", "v2"}])
      assert {:error, :not_found} = Query.read("k")
      assert {:ok, "v2"} = Query.read("k2")
    end

    test "rejects an invalid operation and applies nothing" do
      assert {:error, {:invalid_operation, {:bogus, "k"}}} =
               Query.transact([{:write, "ok", 1}, {:bogus, "k"}])

      # The valid op must not have been applied.
      assert {:error, :not_found} = Query.read("ok")
    end
  end

  describe "to_map/0" do
    test "returns the full key space as a map" do
      assert Query.to_map() == %{}

      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      assert Query.to_map() == %{"a" => 1, "b" => 2}
    end

    test "reflects deletes" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.delete("a")

      assert Query.to_map() == %{}
    end
  end

  describe "missing/1" do
    test "returns the keys not present, in input order" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert Query.missing(["a", "b", "c", "d"]) == ["b", "d"]
      assert Query.missing([]) == []
      assert Query.missing(["a", "c"]) == []
    end
  end

  describe "to_list/0" do
    test "returns sorted key/value pairs" do
      assert Query.to_list() == []

      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert Query.to_list() == [{"a", 1}, {"b", 2}, {"c", 3}]
    end
  end

  describe "get/2" do
    test "returns the bare value or the default" do
      {:ok, _} = Query.write("g:1", 42)

      assert Query.get("g:1") == 42
      assert Query.get("g:missing") == nil
      assert Query.get("g:missing", :none) == :none
    end
  end

  describe "fetch!/1" do
    test "returns the value or raises for a missing key" do
      {:ok, _} = Query.write("f:1", 7)
      assert Query.fetch!("f:1") == 7

      assert_raise KeyError, fn -> Query.fetch!("f:missing") end
    end
  end

  describe "get_lazy/2" do
    test "returns the value or the lazily-computed fallback" do
      {:ok, _} = Query.write("l:1", 5)

      assert Query.get_lazy("l:1", fn -> :computed end) == 5
      assert Query.get_lazy("l:missing", fn -> :computed end) == :computed
    end

    test "does not call the fallback on a hit" do
      {:ok, _} = Query.write("l:2", 9)
      test_pid = self()

      assert Query.get_lazy("l:2", fn ->
               send(test_pid, :called)
               :fallback
             end) == 9

      refute_received :called
    end
  end

  describe "append/2 and prepend/2" do
    test "append builds a list in order, creating it when absent" do
      assert {:ok, [:a]} = Query.append("ap:1", :a)
      assert {:ok, [:a, :b]} = Query.append("ap:1", :b)
      assert Query.get("ap:1") == [:a, :b]
    end

    test "prepend adds to the front" do
      assert {:ok, [:a]} = Query.prepend("pp:1", :a)
      assert {:ok, [:b, :a]} = Query.prepend("pp:1", :b)
    end
  end

  describe "add_to_set/2 and remove_from_list/2" do
    test "add_to_set keeps unique elements in insertion order" do
      assert {:ok, [:a]} = Query.add_to_set("set:1", :a)
      assert {:ok, [:a, :b]} = Query.add_to_set("set:1", :b)
      assert {:ok, [:a, :b]} = Query.add_to_set("set:1", :a)
    end

    test "remove_from_list drops every occurrence" do
      {:ok, _} = Query.write("rl:1", [:a, :b, :a, :c])
      assert {:ok, [:b, :c]} = Query.remove_from_list("rl:1", :a)
      assert {:ok, []} = Query.remove_from_list("rl:missing", :x)
    end
  end

  describe "put_field/3 and delete_field/2" do
    test "put_field sets a field, creating the map when absent" do
      assert {:ok, %{name: "a"}} = Query.put_field("h:1", :name, "a")
      assert {:ok, %{name: "a", age: 1}} = Query.put_field("h:1", :age, 1)
    end

    test "delete_field removes a field and is a no-op when absent" do
      {:ok, _} = Query.write("h:2", %{a: 1, b: 2})
      assert {:ok, %{b: 2}} = Query.delete_field("h:2", :a)
      assert {:ok, %{}} = Query.delete_field("h:missing", :x)
    end
  end

  describe "get_field/3" do
    test "reads a field or the default" do
      {:ok, _} = Query.put_field("gf:1", :name, "a")

      assert Query.get_field("gf:1", :name) == "a"
      assert Query.get_field("gf:1", :missing) == nil
      assert Query.get_field("gf:1", :missing, :none) == :none
      assert Query.get_field("gf:absent", :any, :none) == :none
    end

    test "returns the default for non-map values" do
      {:ok, _} = Query.write("gf:2", 123)
      assert Query.get_field("gf:2", :x, :none) == :none
    end
  end

  describe "list_member?/2 and list_length/1" do
    test "reflect the contents of a list value" do
      {:ok, _} = Query.write("lm:1", [:a, :b, :c])

      assert Query.list_member?("lm:1", :b)
      refute Query.list_member?("lm:1", :z)
      assert Query.list_length("lm:1") == 3
    end

    test "are safe for absent or non-list values" do
      {:ok, _} = Query.write("lm:2", 5)

      refute Query.list_member?("lm:2", :a)
      refute Query.list_member?("lm:absent", :a)
      assert Query.list_length("lm:2") == 0
      assert Query.list_length("lm:absent") == 0
    end
  end

  describe "increment_field/3" do
    test "adds to a numeric field, starting from zero" do
      assert {:ok, %{hits: 1}} = Query.increment_field("if:1", :hits)
      assert {:ok, %{hits: 3}} = Query.increment_field("if:1", :hits, 2)
      assert {:ok, %{hits: 3, misses: 5}} = Query.increment_field("if:1", :misses, 5)
    end
  end

  describe "decrement_field/3" do
    test "subtracts from a numeric field, starting from zero" do
      {:ok, _} = Query.write("df:1", %{stock: 10})

      assert {:ok, %{stock: 9}} = Query.decrement_field("df:1", :stock)
      assert {:ok, %{stock: 6}} = Query.decrement_field("df:1", :stock, 3)
      assert {:ok, %{stock: 6, missing: -1}} = Query.decrement_field("df:1", :missing)
    end
  end

  describe "has_field?/2" do
    test "reflects whether a map value has a field" do
      {:ok, _} = Query.put_field("hf:1", :name, "a")

      assert Query.has_field?("hf:1", :name)
      refute Query.has_field?("hf:1", :missing)
      refute Query.has_field?("hf:absent", :name)
    end

    test "is false for non-map values" do
      {:ok, _} = Query.write("hf:2", 5)
      refute Query.has_field?("hf:2", :x)
    end
  end

  describe "pop_field/3" do
    test "removes and returns a field value" do
      {:ok, _} = Query.write("pf:1", %{a: 1, b: 2})

      assert {:ok, 1} = Query.pop_field("pf:1", :a)
      assert Query.get("pf:1") == %{b: 2}
    end

    test "returns the default without writing when absent" do
      assert {:ok, :none} = Query.pop_field("pf:missing", :a, :none)
      refute Query.exists?("pf:missing")

      {:ok, _} = Query.write("pf:2", %{a: 1})
      assert {:ok, :none} = Query.pop_field("pf:2", :missing, :none)
      assert Query.get("pf:2") == %{a: 1}
    end
  end

  describe "keys_between/2" do
    test "returns sorted keys within the inclusive range" do
      for k <- ["a", "b", "c", "d", "e"], do: {:ok, _} = Query.write(k, k)

      assert Query.keys_between("b", "d") == ["b", "c", "d"]
      assert Query.keys_between("c", "c") == ["c"]
      assert Query.keys_between("d", "b") == []
    end
  end

  describe "pairs_between/2" do
    test "returns sorted key/value pairs within the range" do
      for k <- ["a", "b", "c", "d"], do: {:ok, _} = Query.write(k, String.upcase(k))

      assert Query.pairs_between("b", "c") == [{"b", "B"}, {"c", "C"}]
      assert Query.pairs_between("d", "a") == []
    end
  end

  describe "count_between/2" do
    test "counts keys within the inclusive range" do
      for k <- ["a", "b", "c", "d", "e"], do: {:ok, _} = Query.write(k, k)

      assert Query.count_between("b", "d") == 3
      assert Query.count_between("c", "c") == 1
      assert Query.count_between("e", "a") == 0
    end
  end

  describe "first/0 and last/0" do
    test "return the min and max key pairs, nil when empty" do
      assert Query.first() == nil
      assert Query.last() == nil

      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert Query.first() == {"a", 1}
      assert Query.last() == {"c", 3}
    end
  end

  describe "merge_fields/2" do
    test "merges a map of fields, creating the map when absent" do
      assert {:ok, %{a: 1, b: 2}} = Query.merge_fields("mf:1", %{a: 1, b: 2})
      assert {:ok, %{a: 1, b: 3, c: 4}} = Query.merge_fields("mf:1", %{b: 3, c: 4})
    end
  end

  describe "rename_field/3" do
    test "renames a field, preserving its value" do
      {:ok, _} = Query.write("rf:1", %{old: 1, keep: 2})

      assert {:ok, %{new: 1, keep: 2}} = Query.rename_field("rf:1", :old, :new)
    end

    test "is a no-op when the field or key is absent" do
      {:ok, _} = Query.write("rf:2", %{a: 1})
      assert {:ok, %{a: 1}} = Query.rename_field("rf:2", :missing, :x)
      assert {:ok, %{}} = Query.rename_field("rf:absent", :a, :b)
    end
  end

  describe "field_count/1" do
    test "counts the fields of a map value" do
      {:ok, _} = Query.write("fc:1", %{a: 1, b: 2, c: 3})
      assert Query.field_count("fc:1") == 3
    end

    test "is zero for absent or non-map values" do
      {:ok, _} = Query.write("fc:2", 5)
      assert Query.field_count("fc:2") == 0
      assert Query.field_count("fc:absent") == 0
    end
  end

  describe "fields/1" do
    test "returns sorted field keys of a map value" do
      {:ok, _} = Query.write("fl:1", %{c: 3, a: 1, b: 2})
      assert Query.fields("fl:1") == [:a, :b, :c]
    end

    test "is empty for absent or non-map values" do
      {:ok, _} = Query.write("fl:2", 5)
      assert Query.fields("fl:2") == []
      assert Query.fields("fl:absent") == []
    end
  end

  describe "pop_first/1 and pop_last/1" do
    test "pop_first dequeues from the front" do
      {:ok, _} = Query.write("q:1", [:a, :b, :c])

      assert {:ok, :a} = Query.pop_first("q:1")
      assert Query.get("q:1") == [:b, :c]
    end

    test "pop_last pops from the back" do
      {:ok, _} = Query.write("q:2", [:a, :b, :c])

      assert {:ok, :c} = Query.pop_last("q:2")
      assert Query.get("q:2") == [:a, :b]
    end

    test "return nil for empty, absent, or non-list values" do
      {:ok, _} = Query.write("q:3", [])
      assert {:ok, nil} = Query.pop_first("q:3")
      assert {:ok, nil} = Query.pop_last("q:absent")

      {:ok, _} = Query.write("q:4", 5)
      assert {:ok, nil} = Query.pop_first("q:4")
    end
  end

  describe "get_path/3" do
    test "reads a nested value" do
      {:ok, _} = Query.write("cfg", %{db: %{host: "localhost", port: 5432}})

      assert Query.get_path("cfg", [:db, :host]) == "localhost"
      assert Query.get_path("cfg", [:db, :port]) == 5432
      assert Query.get_path("cfg", [:db]) == %{host: "localhost", port: 5432}
    end

    test "returns the default for missing paths, keys, or non-maps" do
      {:ok, _} = Query.write("cfg2", %{a: 1})

      assert Query.get_path("cfg2", [:a, :b], :none) == :none
      assert Query.get_path("cfg2", [:missing], :none) == :none
      assert Query.get_path("absent", [:a], :none) == :none
    end
  end

  describe "put_path/3" do
    test "sets a nested value, creating intermediate maps" do
      assert {:ok, %{db: %{host: "localhost"}}} =
               Query.put_path("pp:1", [:db, :host], "localhost")

      assert {:ok, %{db: %{host: "localhost", port: 5432}}} =
               Query.put_path("pp:1", [:db, :port], 5432)

      assert Query.get_path("pp:1", [:db, :host]) == "localhost"
    end

    test "replaces a stored non-map with a fresh map" do
      {:ok, _} = Query.write("pp:2", 5)
      assert {:ok, %{a: %{b: 1}}} = Query.put_path("pp:2", [:a, :b], 1)
    end
  end

  describe "delete_path/2" do
    test "removes a nested key" do
      {:ok, _} = Query.write("dp:1", %{db: %{host: "h", port: 1}})

      assert {:ok, %{db: %{port: 1}}} = Query.delete_path("dp:1", [:db, :host])
    end

    test "is a no-op for missing paths or non-maps" do
      {:ok, _} = Query.write("dp:2", %{a: 1})
      assert {:ok, %{a: 1}} = Query.delete_path("dp:2", [:x, :y])

      {:ok, _} = Query.write("dp:3", 5)
      assert {:ok, 5} = Query.delete_path("dp:3", [:a])
    end
  end

  describe "has_path?/2" do
    test "reflects whether a nested path resolves" do
      {:ok, _} = Query.write("hp:1", %{db: %{host: "h"}})

      assert Query.has_path?("hp:1", [:db, :host])
      assert Query.has_path?("hp:1", [:db])
      refute Query.has_path?("hp:1", [:db, :missing])
      refute Query.has_path?("hp:absent", [:db])
    end
  end

  describe "update_path/3" do
    test "updates a nested value, seeding nil when unset" do
      assert {:ok, %{db: %{conns: 1}}} =
               Query.update_path("up:1", [:db, :conns], fn
                 nil -> 1
                 n -> n + 1
               end)

      assert {:ok, %{db: %{conns: 2}}} = Query.update_path("up:1", [:db, :conns], &(&1 + 1))
    end
  end

  describe "bump_max/2 and bump_min/2" do
    test "bump_max keeps the running maximum" do
      assert {:ok, 5} = Query.bump_max("wm:max", 5)
      assert {:ok, 8} = Query.bump_max("wm:max", 8)
      assert {:ok, 8} = Query.bump_max("wm:max", 3)
    end

    test "bump_min keeps the running minimum" do
      assert {:ok, 5} = Query.bump_min("wm:min", 5)
      assert {:ok, 2} = Query.bump_min("wm:min", 2)
      assert {:ok, 2} = Query.bump_min("wm:min", 9)
    end
  end

  describe "summary/0" do
    test "gives a compact overview consistent with info/0" do
      {:ok, _} = Query.write("s:1", 1)

      summary = Query.summary()
      {:ok, info} = Query.info()

      assert summary.keys == info.store.size
      assert summary.durable == info.store.durable
      assert summary.cache_hit_ratio == info.cache.hit_ratio
      assert is_integer(summary.cache_size)
    end
  end

  describe "values/0" do
    test "returns all values in key order" do
      assert Query.values() == []

      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert Query.values() == [1, 2, 3]
    end
  end

  describe "warm/1" do
    test "populates the cache and counts the keys found" do
      {:ok, _} = Query.write("w:1", 1)
      {:ok, _} = Query.write("w:2", 2)
      Query.Cache.clear()

      assert Query.warm(["w:1", "w:2", "w:missing"]) == 2
      assert Query.Cache.cached?("w:1")
      assert Query.Cache.cached?("w:2")
    end
  end

  describe "exists_all?/1 and exists_any?/1" do
    test "reflect presence across a set of keys" do
      {:ok, _} = Query.write("ea:1", 1)
      {:ok, _} = Query.write("ea:2", 2)

      assert Query.exists_all?(["ea:1", "ea:2"])
      refute Query.exists_all?(["ea:1", "ea:missing"])
      assert Query.exists_all?([])

      assert Query.exists_any?(["ea:missing", "ea:1"])
      refute Query.exists_any?(["ea:missing"])
      refute Query.exists_any?([])
    end
  end

  describe "filter/1 and count_where/1" do
    test "select and count pairs by predicate" do
      {:ok, _} = Query.write("n:1", 10)
      {:ok, _} = Query.write("n:2", 20)
      {:ok, _} = Query.write("n:3", 5)

      big = Query.filter(fn {_k, v} -> v >= 10 end)
      assert big == [{"n:1", 10}, {"n:2", 20}]
      assert Query.count_where(fn {_k, v} -> v >= 10 end) == 2
    end
  end

  describe "find/1" do
    test "returns the first matching pair or nil" do
      {:ok, _} = Query.write("f:1", 10)
      {:ok, _} = Query.write("f:2", 20)

      assert Query.find(fn {_k, v} -> v >= 15 end) == {"f:2", 20}
      assert Query.find(fn {_k, v} -> v > 100 end) == nil
    end
  end

  describe "keys_where/1" do
    test "returns the keys whose value matches, sorted" do
      {:ok, _} = Query.write("k:1", 10)
      {:ok, _} = Query.write("k:2", 20)
      {:ok, _} = Query.write("k:3", 5)

      assert Query.keys_where(fn v -> v >= 10 end) == ["k:1", "k:2"]
      assert Query.keys_where(fn v -> v > 100 end) == []
    end
  end

  describe "map_values/1" do
    test "projects every value in key order" do
      {:ok, _} = Query.write("m:1", 1)
      {:ok, _} = Query.write("m:2", 2)
      {:ok, _} = Query.write("m:3", 3)

      assert Query.map_values(&(&1 * 10)) == [10, 20, 30]
      assert Query.map_values(& &1) == [1, 2, 3]
    end
  end

  describe "reduce/2" do
    test "folds over all pairs in key order" do
      {:ok, _} = Query.write("r:1", 1)
      {:ok, _} = Query.write("r:2", 2)
      {:ok, _} = Query.write("r:3", 3)

      sum = Query.reduce(0, fn {_k, v}, acc -> acc + v end)
      assert sum == 6

      keys = Query.reduce([], fn {k, _v}, acc -> [k | acc] end)
      assert Enum.reverse(keys) == ["r:1", "r:2", "r:3"]
    end
  end

  describe "pop_min/0 and pop_max/0" do
    test "remove and return the extreme key pairs" do
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert {:ok, {"a", 1}} = Query.pop_min()
      assert {:ok, {"c", 3}} = Query.pop_max()
      refute Query.exists?("a")
      refute Query.exists?("c")
    end

    test "return nil for an empty store" do
      assert {:ok, nil} = Query.pop_min()
      assert {:ok, nil} = Query.pop_max()
    end
  end

  describe "sum_values/0" do
    test "sums numeric values, ignoring others" do
      assert Query.sum_values() == 0

      {:ok, _} = Query.write("s:1", 10)
      {:ok, _} = Query.write("s:2", 5)
      {:ok, _} = Query.write("s:3", "not a number")

      assert Query.sum_values() == 15
    end
  end

  describe "group_keys_by/1" do
    test "groups keys by a value function" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("c", 3)

      assert Query.group_keys_by(fn v -> rem(v, 2) end) == %{0 => ["b"], 1 => ["a", "c"]}
    end
  end

  describe "avg_values/0" do
    test "averages numeric values, ignoring others" do
      assert Query.avg_values() == 0.0

      {:ok, _} = Query.write("a:1", 10)
      {:ok, _} = Query.write("a:2", 20)
      {:ok, _} = Query.write("a:3", "skip")

      assert Query.avg_values() == 15.0
    end
  end

  describe "max_value/0 and min_value/0" do
    test "return the numeric extremes or nil" do
      assert Query.max_value() == nil
      assert Query.min_value() == nil

      {:ok, _} = Query.write("v:1", 10)
      {:ok, _} = Query.write("v:2", 3)
      {:ok, _} = Query.write("v:3", "skip")

      assert Query.max_value() == 10
      assert Query.min_value() == 3
    end
  end

  describe "value_stats/0" do
    test "summarizes numeric values" do
      empty = Query.value_stats()
      assert empty == %{count: 0, sum: 0, min: nil, max: nil, avg: 0.0}

      {:ok, _} = Query.write("vs:1", 10)
      {:ok, _} = Query.write("vs:2", 20)
      {:ok, _} = Query.write("vs:3", "skip")

      stats = Query.value_stats()
      assert stats.count == 2
      assert stats.sum == 30
      assert stats.min == 10
      assert stats.max == 20
      assert stats.avg == 15.0
    end
  end

  describe "present/1" do
    test "returns the keys that exist, in input order" do
      {:ok, _} = Query.write("p:1", 1)
      {:ok, _} = Query.write("p:3", 3)

      assert Query.present(["p:1", "p:2", "p:3", "p:4"]) == ["p:1", "p:3"]
      assert Query.present([]) == []
    end
  end

  describe "any?/0" do
    test "is the complement of empty?/0" do
      assert Query.empty?()
      refute Query.any?()

      {:ok, _} = Query.write("x", 1)
      assert Query.any?()
      refute Query.empty?()
    end
  end

  describe "drain_prefix/1" do
    test "removes and returns the matching pairs" do
      {:ok, _} = Query.write("job:1", "a")
      {:ok, _} = Query.write("job:2", "b")
      {:ok, _} = Query.write("other", "c")

      assert {:ok, pairs} = Query.drain_prefix("job:")
      assert pairs == [{"job:1", "a"}, {"job:2", "b"}]
      refute Query.exists?("job:1")
      refute Query.exists?("job:2")
      assert Query.exists?("other")
    end
  end

  describe "namespaces/1" do
    test "returns distinct sorted key namespaces" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)
      {:ok, _} = Query.write("flat", 4)

      assert Query.namespaces() == ["flat", "order", "user"]
    end
  end

  describe "namespace_counts/1" do
    test "counts keys per namespace" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)

      assert Query.namespace_counts() == %{"user" => 2, "order" => 1}
    end
  end

  describe "map_prefix/1" do
    test "returns matching pairs as a map" do
      {:ok, _} = Query.write("cfg:a", 1)
      {:ok, _} = Query.write("cfg:b", 2)
      {:ok, _} = Query.write("other", 3)

      assert Query.map_prefix("cfg:") == %{"cfg:a" => 1, "cfg:b" => 2}
      assert Query.map_prefix("none:") == %{}
    end
  end

  describe "count_existing/1" do
    test "counts the keys that exist" do
      {:ok, _} = Query.write("ce:1", 1)
      {:ok, _} = Query.write("ce:2", 2)

      assert Query.count_existing(["ce:1", "ce:2", "ce:missing"]) == 2
      assert Query.count_existing([]) == 0
    end
  end

  describe "all?/1" do
    test "checks a predicate over every pair" do
      assert Query.all?(fn {_k, _v} -> false end)

      {:ok, _} = Query.write("p:1", 2)
      {:ok, _} = Query.write("p:2", 4)

      assert Query.all?(fn {_k, v} -> rem(v, 2) == 0 end)
      refute Query.all?(fn {_k, v} -> v > 3 end)
    end
  end

  describe "exists_pair?/1" do
    test "checks whether any pair matches" do
      refute Query.exists_pair?(fn {_k, _v} -> true end)

      {:ok, _} = Query.write("ep:1", 1)
      {:ok, _} = Query.write("ep:2", 9)

      assert Query.exists_pair?(fn {_k, v} -> v > 5 end)
      refute Query.exists_pair?(fn {_k, v} -> v > 100 end)
    end
  end

  describe "distinct_values/0" do
    test "returns sorted unique values" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("c", 1)

      assert Query.distinct_values() == [1, 2]
    end
  end

  describe "max_by_value/0 and min_by_value/0" do
    test "return the extreme numeric pairs or nil" do
      assert Query.max_by_value() == nil
      assert Query.min_by_value() == nil

      {:ok, _} = Query.write("a", 10)
      {:ok, _} = Query.write("b", 3)
      {:ok, _} = Query.write("c", "skip")

      assert Query.max_by_value() == {"a", 10}
      assert Query.min_by_value() == {"b", 3}
    end
  end

  describe "each/1" do
    test "iterates over every pair in key order" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      test_pid = self()
      assert Query.each(fn pair -> send(test_pid, pair) end) == :ok

      assert_received {"a", 1}
      assert_received {"b", 2}
    end
  end

  describe "map/1" do
    test "projects each pair in key order" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      assert Query.map(fn {k, v} -> "#{k}=#{v}" end) == ["a=1", "b=2"]
    end
  end

  describe "partition/1" do
    test "splits pairs by a predicate" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 4)
      {:ok, _} = Query.write("c", 2)

      {big, small} = Query.partition(fn {_k, v} -> v >= 3 end)
      assert big == [{"b", 4}]
      assert small == [{"a", 1}, {"c", 2}]
    end
  end

  describe "transform_values/1" do
    test "maps values while preserving keys" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      assert Query.transform_values(&(&1 * 10)) == %{"a" => 10, "b" => 20}
    end
  end

  describe "unique_prefix?/1" do
    test "is true when exactly one key has the prefix" do
      {:ok, _} = Query.write("only:1", 1)
      {:ok, _} = Query.write("dup:1", 1)
      {:ok, _} = Query.write("dup:2", 2)

      assert Query.unique_prefix?("only:")
      refute Query.unique_prefix?("dup:")
      refute Query.unique_prefix?("none:")
    end
  end

  describe "sort_by_value/1" do
    test "orders pairs by a value key" do
      {:ok, _} = Query.write("a", 3)
      {:ok, _} = Query.write("b", 1)
      {:ok, _} = Query.write("c", 2)

      assert Query.sort_by_value(& &1) == [{"b", 1}, {"c", 2}, {"a", 3}]
    end
  end

  describe "numeric_count/0" do
    test "counts numeric values" do
      assert Query.numeric_count() == 0

      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2.5)
      {:ok, _} = Query.write("c", "text")

      assert Query.numeric_count() == 2
    end
  end

  describe "value_counts/0" do
    test "counts keys per distinct value" do
      {:ok, _} = Query.write("a", :x)
      {:ok, _} = Query.write("b", :x)
      {:ok, _} = Query.write("c", :y)

      assert Query.value_counts() == %{x: 2, y: 1}
    end
  end

  describe "keys_matching/1" do
    test "returns sorted keys matching a predicate" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)

      assert Query.keys_matching(&String.starts_with?(&1, "user:")) == ["user:1", "user:2"]
    end
  end

  describe "prefix_empty?/1" do
    test "is true when no key has the prefix" do
      {:ok, _} = Query.write("used:1", 1)

      assert Query.prefix_empty?("free:")
      refute Query.prefix_empty?("used:")
    end
  end

  describe "group_by/1" do
    test "groups pairs by a value function" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("c", 3)

      assert Query.group_by(fn v -> rem(v, 2) end) ==
               %{0 => [{"b", 2}], 1 => [{"a", 1}, {"c", 3}]}
    end
  end

  describe "single?/0" do
    test "is true only with exactly one key" do
      refute Query.single?()

      {:ok, _} = Query.write("a", 1)
      assert Query.single?()

      {:ok, _} = Query.write("b", 2)
      refute Query.single?()
    end
  end

  describe "pairs_with_value/1" do
    test "returns pairs holding a specific value" do
      {:ok, _} = Query.write("a", :x)
      {:ok, _} = Query.write("b", :y)
      {:ok, _} = Query.write("c", :x)

      assert Query.pairs_with_value(:x) == [{"a", :x}, {"c", :x}]
      assert Query.pairs_with_value(:z) == []
    end
  end

  describe "only/0" do
    test "returns the single pair or nil" do
      assert Query.only() == nil

      {:ok, _} = Query.write("k", 1)
      assert Query.only() == {"k", 1}

      {:ok, _} = Query.write("k2", 2)
      assert Query.only() == nil
    end
  end

  describe "sum_of/1" do
    test "sums numeric values for the given keys" do
      {:ok, _} = Query.write("a", 10)
      {:ok, _} = Query.write("b", 5)
      {:ok, _} = Query.write("c", "skip")

      assert Query.sum_of(["a", "b", "c", "missing"]) == 15
      assert Query.sum_of([]) == 0
    end
  end

  describe "all_keys?/1" do
    test "checks a predicate over every key" do
      assert Query.all_keys?(fn _k -> false end)

      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)

      assert Query.all_keys?(&String.starts_with?(&1, "user:"))
      refute Query.all_keys?(&String.starts_with?(&1, "admin:"))
    end
  end

  describe "keys_desc/0" do
    test "returns keys in descending order" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)
      {:ok, _} = Query.write("b", 2)

      assert Query.keys_desc() == ["c", "b", "a"]
    end
  end

  describe "distinct_value_count/0" do
    test "counts unique values" do
      assert Query.distinct_value_count() == 0

      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 1)
      {:ok, _} = Query.write("c", 2)

      assert Query.distinct_value_count() == 2
    end
  end

  describe "count_keys/1" do
    test "counts keys matching a predicate" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)

      assert Query.count_keys(&String.starts_with?(&1, "user:")) == 2
      assert Query.count_keys(fn _ -> false end) == 0
    end
  end

  describe "has_value?/1" do
    test "detects whether any key holds a value" do
      {:ok, _} = Query.write("a", :x)

      assert Query.has_value?(:x)
      refute Query.has_value?(:y)
    end
  end

  describe "keys_for_value/1" do
    test "returns the keys holding a value, sorted" do
      {:ok, _} = Query.write("a", :x)
      {:ok, _} = Query.write("c", :x)
      {:ok, _} = Query.write("b", :y)

      assert Query.keys_for_value(:x) == ["a", "c"]
      assert Query.keys_for_value(:z) == []
    end
  end

  describe "keys_in_namespace/2" do
    test "returns sorted keys under a namespace" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)
      {:ok, _} = Query.write("user", 4)

      assert Query.keys_in_namespace("user") == ["user:1", "user:2"]
      assert Query.keys_in_namespace("none") == []
    end
  end

  describe "to_entries/0" do
    test "returns key/value maps sorted by key" do
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)

      assert Query.to_entries() == [%{key: "a", value: 1}, %{key: "b", value: 2}]
    end
  end

  describe "values_desc/0" do
    test "returns values in descending key order" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)
      {:ok, _} = Query.write("b", 2)

      assert Query.values_desc() == [3, 2, 1]
    end
  end

  describe "partition_keys/1" do
    test "splits keys by a predicate, each sorted" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("order:1", 2)
      {:ok, _} = Query.write("user:2", 3)

      {users, rest} = Query.partition_keys(&String.starts_with?(&1, "user:"))
      assert users == ["user:1", "user:2"]
      assert rest == ["order:1"]
    end
  end

  describe "key_range/0" do
    test "returns the min and max keys or nil" do
      assert Query.key_range() == nil

      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)

      assert Query.key_range() == {"a", "c"}
    end
  end

  describe "count_values/1" do
    test "counts values matching a predicate" do
      {:ok, _} = Query.write("a", 10)
      {:ok, _} = Query.write("b", 20)
      {:ok, _} = Query.write("c", 5)

      assert Query.count_values(fn v -> v >= 10 end) == 2
      assert Query.count_values(fn _ -> false end) == 0
    end
  end

  describe "to_keyword/0" do
    test "converts string keys with existing atoms to a keyword list" do
      # Ensure the atoms exist.
      _ = [:kw_a, :kw_b]
      {:ok, _} = Query.write("kw_a", 1)
      {:ok, _} = Query.write("kw_b", 2)
      {:ok, _} = Query.write("kw_no_such_atom_xyz", 3)

      kw = Query.to_keyword()
      assert kw[:kw_a] == 1
      assert kw[:kw_b] == 2
    end
  end

  describe "find_key/1" do
    test "returns the first pair whose key matches" do
      {:ok, _} = Query.write("a:1", 1)
      {:ok, _} = Query.write("b:1", 2)
      {:ok, _} = Query.write("b:2", 3)

      assert Query.find_key(&String.starts_with?(&1, "b:")) == {"b:1", 2}
      assert Query.find_key(&String.starts_with?(&1, "z:")) == nil
    end
  end

  describe "all_values?/1" do
    test "checks a predicate over every value" do
      assert Query.all_values?(fn _v -> false end)

      {:ok, _} = Query.write("a", 2)
      {:ok, _} = Query.write("b", 4)

      assert Query.all_values?(fn v -> rem(v, 2) == 0 end)
      refute Query.all_values?(fn v -> v > 3 end)
    end
  end

  describe "first_key_where/1" do
    test "returns the smallest key whose value matches" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 5)
      {:ok, _} = Query.write("c", 9)

      assert Query.first_key_where(fn v -> v >= 5 end) == "b"
      assert Query.first_key_where(fn v -> v > 100 end) == nil
    end
  end

  describe "slice/1" do
    test "projects the store onto a key set" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)
      {:ok, _} = Query.write("c", 3)

      assert Query.slice(["a", "c", "missing"]) == [{"a", 1}, {"c", 3}]
      assert Query.slice([]) == []
    end
  end

  describe "rekey/1" do
    test "renames keys via a function atomically" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      assert {:ok, :committed} = Query.rekey(fn key -> "x:" <> key end)

      assert Query.get("x:a") == 1
      assert Query.get("x:b") == 2
      refute Query.exists?("a")
      refute Query.exists?("b")
    end
  end

  describe "group_by_namespace/1" do
    test "nests keys by namespace" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)

      assert Query.group_by_namespace() == %{
               "user" => %{"user:1" => 1, "user:2" => 2},
               "order" => %{"order:1" => 3}
             }
    end
  end

  describe "count_in_namespace/2" do
    test "counts keys under a namespace" do
      {:ok, _} = Query.write("user:1", 1)
      {:ok, _} = Query.write("user:2", 2)
      {:ok, _} = Query.write("order:1", 3)

      assert Query.count_in_namespace("user") == 2
      assert Query.count_in_namespace("none") == 0
    end
  end

  describe "has_exactly?/1" do
    test "checks the exact key set" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", 2)

      assert Query.has_exactly?(["a", "b"])
      assert Query.has_exactly?(["b", "a"])
      refute Query.has_exactly?(["a"])
      refute Query.has_exactly?(["a", "b", "c"])
    end
  end

  describe "string_keys?/0" do
    test "is true when all keys are binaries" do
      assert Query.string_keys?()

      {:ok, _} = Query.write("a", 1)
      assert Query.string_keys?()

      {:ok, _} = Query.write(:atom_key, 2)
      refute Query.string_keys?()
    end
  end

  describe "numeric_pairs/0" do
    test "returns only numeric-valued pairs, sorted" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("b", "text")
      {:ok, _} = Query.write("c", 3)

      assert Query.numeric_pairs() == [{"a", 1}, {"c", 3}]
    end
  end

  describe "top_n/1" do
    test "returns the largest numeric pairs" do
      {:ok, _} = Query.write("a", 5)
      {:ok, _} = Query.write("b", 20)
      {:ok, _} = Query.write("c", 10)
      {:ok, _} = Query.write("d", "skip")

      assert Query.top_n(2) == [{"b", 20}, {"c", 10}]
      assert Query.top_n(0) == []
    end
  end

  describe "bottom_n/1" do
    test "returns the smallest numeric pairs" do
      {:ok, _} = Query.write("a", 5)
      {:ok, _} = Query.write("b", 20)
      {:ok, _} = Query.write("c", 10)

      assert Query.bottom_n(2) == [{"a", 5}, {"c", 10}]
      assert Query.bottom_n(0) == []
    end
  end

  describe "page/2" do
    test "returns a page of pairs by offset and limit" do
      for k <- ["a", "b", "c", "d", "e"], do: {:ok, _} = Query.write(k, k)

      assert Query.page(0, 2) == [{"a", "a"}, {"b", "b"}]
      assert Query.page(2, 2) == [{"c", "c"}, {"d", "d"}]
      assert Query.page(4, 10) == [{"e", "e"}]
      assert Query.page(10, 5) == []
    end
  end

  describe "increment_namespace/3" do
    test "bumps every numeric value under a namespace" do
      {:ok, _} = Query.write("counter:a", 1)
      {:ok, _} = Query.write("counter:b", 5)
      {:ok, _} = Query.write("other:1", 100)

      assert {:ok, :committed} = Query.increment_namespace("counter", 2)

      assert Query.get("counter:a") == 3
      assert Query.get("counter:b") == 7
      assert Query.get("other:1") == 100
    end
  end

  describe "floor_entry/1" do
    test "returns the largest pair with key <= the given key" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)
      {:ok, _} = Query.write("e", 5)

      assert Query.floor_entry("d") == {"c", 3}
      assert Query.floor_entry("c") == {"c", 3}
      assert Query.floor_entry("a") == {"a", 1}
      assert Query.floor_entry("0") == nil
    end
  end

  describe "ceiling_entry/1" do
    test "returns the smallest pair with key >= the given key" do
      {:ok, _} = Query.write("a", 1)
      {:ok, _} = Query.write("c", 3)
      {:ok, _} = Query.write("e", 5)

      assert Query.ceiling_entry("b") == {"c", 3}
      assert Query.ceiling_entry("c") == {"c", 3}
      assert Query.ceiling_entry("e") == {"e", 5}
      assert Query.ceiling_entry("z") == nil
    end
  end

  describe "value_bounds/0" do
    test "returns the numeric min and max or nil" do
      assert Query.value_bounds() == nil

      {:ok, _} = Query.write("a", 10)
      {:ok, _} = Query.write("b", 3)
      {:ok, _} = Query.write("c", "skip")

      assert Query.value_bounds() == {3, 10}
    end
  end

  describe "neighbors/1" do
    test "returns the adjacent keys in sorted order" do
      for k <- ["a", "c", "e"], do: {:ok, _} = Query.write(k, k)

      assert Query.neighbors("c") == {"a", "e"}
      assert Query.neighbors("d") == {"c", "e"}
      assert Query.neighbors("a") == {nil, "c"}
      assert Query.neighbors("z") == {"e", nil}
    end
  end
end
