defmodule Query.CasTest do
  @moduledoc "Compare-and-swap semantics for optimistic concurrency."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "insert-if-absent succeeds once, then fails while present" do
    assert {:ok, :swapped} = Query.cas("k", :absent, "v1")
    assert {:ok, "v1"} = Query.read("k")

    assert {:error, :precondition_failed} = Query.cas("k", :absent, "v2")
    assert {:ok, "v1"} = Query.read("k")
  end

  test "swap succeeds on a matching expected value and fails otherwise" do
    {:ok, :swapped} = Query.cas("k", :absent, 1)

    assert {:ok, :swapped} = Query.cas("k", 1, 2)
    assert {:ok, 2} = Query.read("k")

    # Current is 2, so expecting 1 must fail.
    assert {:error, :precondition_failed} = Query.cas("k", 1, 3)
    assert {:ok, 2} = Query.read("k")
  end

  test "a successful swap invalidates the read cache (no stale read)" do
    {:ok, :swapped} = Query.cas("k", :absent, "a")
    # Populate the cache.
    assert {:ok, "a"} = Query.read("k")

    assert {:ok, :swapped} = Query.cas("k", "a", "b")
    assert {:ok, "b"} = Query.read("k")
  end
end
