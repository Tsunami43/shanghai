defmodule Query.MdeleteTest do
  @moduledoc "Atomic bulk delete, the counterpart to mset/1."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "deletes every listed key" do
    {:ok, :committed} = Query.mset(%{"a" => 1, "b" => 2, "c" => 3})

    assert {:ok, :committed} = Query.mdelete(["a", "c"])

    assert {:error, :not_found} = Query.read("a")
    assert {:ok, 2} = Query.read("b")
    assert {:error, :not_found} = Query.read("c")
  end

  test "is idempotent for missing keys" do
    assert {:ok, :committed} = Query.mdelete(["never", "gone"])
  end

  test "an empty list commits nothing" do
    {:ok, :written} = Query.write("keep", 1)
    assert {:ok, :committed} = Query.mdelete([])
    assert {:ok, 1} = Query.read("keep")
  end

  test "invalidates the cache for deleted keys" do
    {:ok, :written} = Query.write("k", 1)
    assert {:ok, 1} = Query.read("k")

    {:ok, :committed} = Query.mdelete(["k"])
    assert {:error, :not_found} = Query.read("k")
  end
end
