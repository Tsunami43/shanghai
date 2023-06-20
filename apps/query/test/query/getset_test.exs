defmodule Query.GetsetTest do
  @moduledoc "Atomic get-and-set returning the previous value."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "returns :absent for a missing key and stores the value" do
    assert {:ok, :absent} = Query.getset("leader", "node-a")
    assert {:ok, "node-a"} = Query.read("leader")
  end

  test "returns the previous value and replaces it" do
    {:ok, :absent} = Query.getset("leader", "node-a")
    assert {:ok, "node-a"} = Query.getset("leader", "node-b")
    assert {:ok, "node-b"} = Query.read("leader")
  end

  test "invalidates the cache so a subsequent read sees the new value" do
    {:ok, :written} = Query.write("k", 1)
    assert {:ok, 1} = Query.read("k")

    assert {:ok, 1} = Query.getset("k", 2)
    assert {:ok, 2} = Query.read("k")
  end
end
