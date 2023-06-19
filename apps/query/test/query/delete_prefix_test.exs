defmodule Query.DeletePrefixTest do
  @moduledoc "Range delete: remove every key under a prefix atomically."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "deletes only the keys under the prefix" do
    {:ok, :written} = Query.write("session:1:a", 1)
    {:ok, :written} = Query.write("session:1:b", 2)
    {:ok, :written} = Query.write("session:2:a", 3)

    assert {:ok, {:deleted, 2}} = Query.delete_prefix("session:1:")

    assert {:error, :not_found} = Query.read("session:1:a")
    assert {:error, :not_found} = Query.read("session:1:b")
    assert {:ok, 3} = Query.read("session:2:a")
  end

  test "returns a zero count when nothing matches" do
    assert {:ok, {:deleted, 0}} = Query.delete_prefix("nope:")
  end

  test "invalidates the cache for the removed keys" do
    {:ok, :written} = Query.write("k:1", 1)
    assert {:ok, 1} = Query.read("k:1")

    assert {:ok, {:deleted, 1}} = Query.delete_prefix("k:")
    assert {:error, :not_found} = Query.read("k:1")
  end
end
