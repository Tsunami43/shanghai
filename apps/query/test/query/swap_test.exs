defmodule Query.SwapTest do
  @moduledoc "swap/2: atomically exchange the values of two keys."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "exchanges the values of two existing keys" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)

    assert {:ok, :swapped} = Query.swap("a", "b")
    assert {:ok, 2} = Query.read("a")
    assert {:ok, 1} = Query.read("b")
  end

  test "returns :not_found when either key is absent" do
    {:ok, :written} = Query.write("a", 1)

    assert {:error, :not_found} = Query.swap("a", "missing")
    assert {:error, :not_found} = Query.swap("missing", "a")
    assert {:ok, 1} = Query.read("a")
  end

  test "invalidates the cache for both keys" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)
    assert {:ok, 1} = Query.read("a")
    assert {:ok, 2} = Query.read("b")

    {:ok, :swapped} = Query.swap("a", "b")
    assert {:ok, 2} = Query.read("a")
    assert {:ok, 1} = Query.read("b")
  end
end
