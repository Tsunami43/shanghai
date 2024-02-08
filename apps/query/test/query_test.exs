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
end
