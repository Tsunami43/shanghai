defmodule Query.TakeTest do
  @moduledoc "Atomic get-and-delete (Query.take/1)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "take returns the value and removes the key" do
    {:ok, :written} = Query.write("job:1", %{task: :send})

    assert {:ok, %{task: :send}} = Query.take("job:1")
    assert {:error, :not_found} = Query.read("job:1")
  end

  test "take on a missing key returns :not_found" do
    assert {:error, :not_found} = Query.take("nope")
  end

  test "take invalidates a cached read" do
    {:ok, :written} = Query.write("k", "v")
    # Populate the cache.
    assert {:ok, "v"} = Query.read("k")

    assert {:ok, "v"} = Query.take("k")
    assert {:error, :not_found} = Query.read("k")
  end
end
