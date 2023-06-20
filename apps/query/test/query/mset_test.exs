defmodule Query.MsetTest do
  @moduledoc "Atomic bulk write, the counterpart to mget/1."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "writes every pair from a map" do
    assert {:ok, :committed} = Query.mset(%{"a" => 1, "b" => 2})
    assert {:ok, %{"a" => 1, "b" => 2}} = Query.mget(["a", "b"])
  end

  test "writes every pair from a list" do
    assert {:ok, :committed} = Query.mset([{"x", 10}, {"y", 20}])
    assert {:ok, 10} = Query.read("x")
    assert {:ok, 20} = Query.read("y")
  end

  test "an empty collection commits nothing" do
    assert {:ok, :committed} = Query.mset(%{})
    assert 0 = Query.count()
  end

  test "invalidates the cache for written keys" do
    {:ok, :written} = Query.write("a", 0)
    assert {:ok, 0} = Query.read("a")

    {:ok, :committed} = Query.mset(%{"a" => 99})
    assert {:ok, 99} = Query.read("a")
  end
end
