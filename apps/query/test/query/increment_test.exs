defmodule Query.IncrementTest do
  @moduledoc "Atomic counter semantics (Query.increment/2)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "a missing key starts from zero" do
    assert {:ok, 1} = Query.increment("hits")
    assert {:ok, 1} = Query.read("hits")
  end

  test "increments accumulate and honor a custom amount" do
    {:ok, 1} = Query.increment("hits")
    assert {:ok, 6} = Query.increment("hits", 5)
    assert {:ok, 4} = Query.increment("hits", -2)
    assert {:ok, 4} = Query.read("hits")
  end

  test "a non-numeric value is rejected" do
    {:ok, :written} = Query.write("k", "not a number")
    assert {:error, :not_a_number} = Query.increment("k")
    assert {:ok, "not a number"} = Query.read("k")
  end

  test "decrement subtracts, defaulting to 1 and treating a missing key as 0" do
    {:ok, :written} = Query.write("stock", 10)
    assert {:ok, 7} = Query.decrement("stock", 3)
    assert {:ok, 6} = Query.decrement("stock")
    assert {:ok, -1} = Query.decrement("fresh")
  end

  test "increment invalidates the read cache" do
    {:ok, 1} = Query.increment("c")
    # Populate the cache.
    assert {:ok, 1} = Query.read("c")

    {:ok, 2} = Query.increment("c")
    assert {:ok, 2} = Query.read("c")
  end
end
