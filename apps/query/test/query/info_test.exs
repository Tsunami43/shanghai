defmodule Query.InfoTest do
  @moduledoc "Runtime introspection of the query layer."

  use ExUnit.Case, async: false

  doctest Query, only: [info: 0]

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "info reports store and cache sections" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)
    # Populate the read cache.
    {:ok, 1} = Query.read("a")

    assert {:ok, info} = Query.info()

    assert info.store.size == 2
    assert is_boolean(info.store.durable)
    assert is_integer(info.store.recovered)

    assert info.cache.size >= 1
    assert is_integer(info.cache.max_size)
  end
end
