defmodule Query.UpdateTest do
  @moduledoc "Atomic read-modify-write (Query.update/3)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "uses the default for a missing key" do
    assert {:ok, 1} = Query.update("counter", 0, &(&1 + 1))
    assert {:ok, 1} = Query.read("counter")
  end

  test "transforms an existing value" do
    {:ok, :written} = Query.write("tags", ["a"])
    assert {:ok, ["b", "a"]} = Query.update("tags", [], &["b" | &1])
    assert {:ok, ["b", "a"]} = Query.read("tags")
  end

  test "a raising function returns an error and leaves the value unchanged" do
    {:ok, :written} = Query.write("k", 1)

    assert {:error, {:update_failed, _msg}} = Query.update("k", 0, fn _ -> raise "boom" end)
    assert {:ok, 1} = Query.read("k")
  end

  test "update invalidates a cached read" do
    {:ok, :written} = Query.write("k", 1)
    assert {:ok, 1} = Query.read("k")

    assert {:ok, 2} = Query.update("k", 0, &(&1 + 1))
    assert {:ok, 2} = Query.read("k")
  end
end
