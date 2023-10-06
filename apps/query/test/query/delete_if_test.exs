defmodule Query.DeleteIfTest do
  @moduledoc "delete_if/2: conditional delete (delete-if-equals)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "deletes when the value matches" do
    {:ok, :written} = Query.write("lock", "owner-a")
    assert {:ok, :deleted} = Query.delete_if("lock", "owner-a")
    assert {:error, :not_found} = Query.read("lock")
  end

  test "refuses to delete on a value mismatch" do
    {:ok, :written} = Query.write("lock", "owner-a")
    assert {:error, :precondition_failed} = Query.delete_if("lock", "owner-b")
    assert {:ok, "owner-a"} = Query.read("lock")
  end

  test "returns :not_found for a missing key" do
    assert {:error, :not_found} = Query.delete_if("missing", "x")
  end

  test "invalidates the cache on a successful delete" do
    {:ok, :written} = Query.write("k", 1)
    assert {:ok, 1} = Query.read("k")

    assert {:ok, :deleted} = Query.delete_if("k", 1)
    assert {:error, :not_found} = Query.read("k")
  end
end
