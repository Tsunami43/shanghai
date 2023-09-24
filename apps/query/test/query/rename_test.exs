defmodule Query.RenameTest do
  @moduledoc "rename/2: atomically move a value from one key to another."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "moves the value and removes the old key" do
    {:ok, :written} = Query.write("draft:1", "text")

    assert {:ok, :renamed} = Query.rename("draft:1", "post:1")
    assert {:error, :not_found} = Query.read("draft:1")
    assert {:ok, "text"} = Query.read("post:1")
  end

  test "returns :not_found for a missing source" do
    assert {:error, :not_found} = Query.rename("missing", "dest")
    assert {:error, :not_found} = Query.read("dest")
  end

  test "overwrites an existing destination" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)

    assert {:ok, :renamed} = Query.rename("a", "b")
    assert {:ok, 1} = Query.read("b")
    assert {:error, :not_found} = Query.read("a")
  end

  test "invalidates the cache for both keys" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 9)
    assert {:ok, 1} = Query.read("a")
    assert {:ok, 9} = Query.read("b")

    {:ok, :renamed} = Query.rename("a", "b")
    assert {:ok, 1} = Query.read("b")
  end
end
