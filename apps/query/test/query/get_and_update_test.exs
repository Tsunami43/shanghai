defmodule Query.GetAndUpdateTest do
  @moduledoc "get_and_update/2: Access-style atomic get-and-update."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "returns the old value and stores the new one" do
    {:ok, :written} = Query.write("counter", 5)

    assert {:ok, 5} = Query.get_and_update("counter", fn v -> {v, v + 1} end)
    assert {:ok, 6} = Query.read("counter")
  end

  test "treats a missing key as nil" do
    assert {:ok, nil} = Query.get_and_update("new", fn v -> {v, "init"} end)
    assert {:ok, "init"} = Query.read("new")
  end

  test "pop deletes the key and returns the previous value" do
    {:ok, :written} = Query.write("k", "v")

    assert {:ok, "v"} = Query.get_and_update("k", fn _ -> :pop end)
    assert {:error, :not_found} = Query.read("k")
  end

  test "a raising function is reported without persisting" do
    {:ok, :written} = Query.write("k", 1)
    assert {:error, {:update_failed, _}} = Query.get_and_update("k", fn _ -> raise "boom" end)
    assert {:ok, 1} = Query.read("k")
  end
end
