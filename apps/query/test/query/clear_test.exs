defmodule Query.ClearTest do
  @moduledoc "clear/0: durable removal of every key."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "removes every key and flushes the cache" do
    {:ok, :committed} = Query.mset(%{"a" => 1, "b" => 2, "c" => 3})
    assert Query.count() == 3
    {:ok, 1} = Query.read("a")

    assert {:ok, :cleared} = Query.clear()

    assert Query.count() == 0
    assert {:error, :not_found} = Query.read("a")
    assert {:error, :not_found} = Query.read("b")
  end

  test "is a no-op result on an already-empty store" do
    assert {:ok, :cleared} = Query.clear()
    assert Query.count() == 0
  end
end
