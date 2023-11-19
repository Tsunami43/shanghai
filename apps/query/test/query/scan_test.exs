defmodule Query.ScanTest do
  @moduledoc "Iteration/collection access over the query layer."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "scan returns sorted pairs matching a prefix" do
    {:ok, :written} = Query.write("events:o1:1", "a")
    {:ok, :written} = Query.write("events:o1:2", "b")
    {:ok, :written} = Query.write("events:o2:1", "c")
    {:ok, :written} = Query.write("users:1", "d")

    assert {:ok, [{"events:o1:1", "a"}, {"events:o1:2", "b"}]} = Query.scan("events:o1:")
    assert {:ok, pairs} = Query.scan("events:")
    assert length(pairs) == 3
  end

  test "scan respects a :limit" do
    {:ok, :written} = Query.write("p:1", 1)
    {:ok, :written} = Query.write("p:2", 2)
    {:ok, :written} = Query.write("p:3", 3)

    assert {:ok, [{"p:1", 1}, {"p:2", 2}]} = Query.scan("p:", limit: 2)
    assert {:ok, []} = Query.scan("p:", limit: 0)
    assert {:ok, all} = Query.scan("p:", limit: 99)
    assert length(all) == 3
  end

  test "scan on a non-matching prefix returns an empty list" do
    {:ok, :written} = Query.write("k", "v")
    assert {:ok, []} = Query.scan("nope:")
  end

  test "keys and count reflect stored data" do
    assert Query.count() == 0
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)

    assert Query.count() == 2
    assert Enum.sort(Query.keys()) == ["a", "b"]
  end

  test "min_key/0 and max_key/0 return the key extremes" do
    assert Query.min_key() == nil
    assert Query.max_key() == nil

    {:ok, :committed} = Query.mset(%{"b" => 1, "a" => 2, "c" => 3})
    assert Query.min_key() == "a"
    assert Query.max_key() == "c"
  end

  test "empty?/0 reflects whether the store has keys" do
    assert Query.empty?()
    {:ok, :written} = Query.write("k", 1)
    refute Query.empty?()
    {:ok, :deleted} = Query.delete("k")
    assert Query.empty?()
  end

  test "deleted keys drop out of scan/keys" do
    {:ok, :written} = Query.write("p:1", 1)
    {:ok, :written} = Query.write("p:2", 2)
    {:ok, :deleted} = Query.delete("p:1")

    assert {:ok, [{"p:2", 2}]} = Query.scan("p:")
    assert Query.count() == 1
  end
end
