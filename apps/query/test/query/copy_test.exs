defmodule Query.CopyTest do
  @moduledoc "copy/2: duplicate a value to a new key, keeping the source."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  test "copies the value and keeps the source" do
    {:ok, :written} = Query.write("template", %{fields: []})

    assert {:ok, :copied} = Query.copy("template", "doc:1")
    assert {:ok, %{fields: []}} = Query.read("template")
    assert {:ok, %{fields: []}} = Query.read("doc:1")
  end

  test "returns :not_found for a missing source" do
    assert {:error, :not_found} = Query.copy("missing", "dest")
    assert {:error, :not_found} = Query.read("dest")
  end

  test "overwrites an existing destination and invalidates its cache" do
    {:ok, :written} = Query.write("a", 1)
    {:ok, :written} = Query.write("b", 2)
    assert {:ok, 2} = Query.read("b")

    assert {:ok, :copied} = Query.copy("a", "b")
    assert {:ok, 1} = Query.read("b")
    assert {:ok, 1} = Query.read("a")
  end
end
