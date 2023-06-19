defmodule Query.ConditionalWriteTest do
  @moduledoc "put_new (write-if-absent) and replace (write-if-exists)."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  describe "put_new/2" do
    test "writes a missing key, then refuses to overwrite" do
      assert {:ok, :written} = Query.put_new("k", 1)
      assert {:ok, 1} = Query.read("k")

      assert {:error, :exists} = Query.put_new("k", 2)
      assert {:ok, 1} = Query.read("k")
    end
  end

  describe "replace/2" do
    test "replaces an existing key" do
      {:ok, :written} = Query.write("k", 1)
      assert {:ok, :written} = Query.replace("k", 2)
      assert {:ok, 2} = Query.read("k")
    end

    test "refuses a missing key" do
      assert {:error, :not_found} = Query.replace("missing", 1)
      assert {:error, :not_found} = Query.read("missing")
    end
  end

  test "conditional writes invalidate the cache" do
    {:ok, :written} = Query.put_new("k", 1)
    assert {:ok, 1} = Query.read("k")

    {:ok, :written} = Query.replace("k", 2)
    assert {:ok, 2} = Query.read("k")
  end
end
