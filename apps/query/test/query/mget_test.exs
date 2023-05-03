defmodule Query.MgetTest do
  @moduledoc "Batch multi-key reads (Query.mget/1)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "returns only the keys that exist" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)

    assert {:ok, %{"a" => 1, "b" => 2}} = Query.mget(["a", "b", "missing"])
  end

  test "an empty key list yields an empty map" do
    assert {:ok, map} = Query.mget([])
    assert map == %{}
  end

  test "all-missing keys yield an empty map" do
    assert {:ok, map} = Query.mget(["x", "y"])
    assert map == %{}
  end
end
