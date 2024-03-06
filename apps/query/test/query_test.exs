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
end
