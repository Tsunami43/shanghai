defmodule Query.ExistsTest do
  @moduledoc "Cheap read-side helpers: exists?/1 and count_prefix/1."

  use ExUnit.Case, async: false

  setup do
    Query.Store.reset()
    Query.Cache.clear()
    :ok
  end

  describe "exists?/1" do
    test "reflects presence and absence" do
      refute Query.exists?("k")
      {:ok, :written} = Query.write("k", 1)
      assert Query.exists?("k")

      {:ok, :deleted} = Query.delete("k")
      refute Query.exists?("k")
    end
  end

  describe "count_prefix/1" do
    test "counts only the matching keys" do
      {:ok, :committed} = Query.mset(%{"e:1" => 1, "e:2" => 2, "other" => 3})
      assert Query.count_prefix("e:") == 2
      assert Query.count_prefix("nope") == 0
    end
  end
end
