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

  test "deleted keys drop out of scan/keys" do
    {:ok, :written} = Query.write("p:1", 1)
    {:ok, :written} = Query.write("p:2", 2)
    {:ok, :deleted} = Query.delete("p:1")

    assert {:ok, [{"p:2", 2}]} = Query.scan("p:")
    assert Query.count() == 1
  end
end
