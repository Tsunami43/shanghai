defmodule Query.GetOrStoreTest do
  @moduledoc "get_or_store/2: get-or-compute with race-safe population."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "computes and stores a missing key" do
    assert {:ok, %{loaded: true}} = Query.get_or_store("config", fn -> %{loaded: true} end)
    assert {:ok, %{loaded: true}} = Query.read("config")
  end

  test "returns the existing value without calling the function" do
    {:ok, :written} = Query.write("k", 1)

    assert {:ok, 1} =
             Query.get_or_store("k", fn -> raise "must not be called" end)
  end

  test "returns the already-stored value when populated concurrently" do
    # Simulate a racing writer that wins between the read and the put_new.
    result =
      Query.get_or_store("race", fn ->
        {:ok, :written} = Query.put_new("race", :winner)
        :loser
      end)

    assert result == {:ok, :winner}
    assert {:ok, :winner} = Query.read("race")
  end
end
