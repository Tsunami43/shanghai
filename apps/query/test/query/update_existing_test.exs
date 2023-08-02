defmodule Query.UpdateExistingTest do
  @moduledoc "update_existing/2: read-modify-write only when the key exists."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "applies the function to an existing key" do
    {:ok, :written} = Query.write("counter", 1)
    assert {:ok, 2} = Query.update_existing("counter", &(&1 + 1))
    assert {:ok, 2} = Query.read("counter")
  end

  test "does not create a missing key" do
    assert {:error, :not_found} = Query.update_existing("missing", &(&1 + 1))
    assert {:error, :not_found} = Query.read("missing")
  end

  test "reports a raising function without persisting" do
    {:ok, :written} = Query.write("k", 1)
    assert {:error, {:update_failed, _}} = Query.update_existing("k", fn _ -> raise "boom" end)
    assert {:ok, 1} = Query.read("k")
  end

  test "invalidates the cache" do
    {:ok, :written} = Query.write("k", 1)
    assert {:ok, 1} = Query.read("k")

    {:ok, 5} = Query.update_existing("k", fn _ -> 5 end)
    assert {:ok, 5} = Query.read("k")
  end
end
