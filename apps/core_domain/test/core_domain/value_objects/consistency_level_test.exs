defmodule CoreDomain.ValueObjects.ConsistencyLevelTest do
  use ExUnit.Case, async: true

  alias CoreDomain.ValueObjects.ConsistencyLevel

  doctest ConsistencyLevel

  describe "valid?/1 and all/0" do
    test "accepts every level in all/0 and rejects others" do
      for level <- ConsistencyLevel.all() do
        assert ConsistencyLevel.valid?(level)
      end

      refute ConsistencyLevel.valid?(:bogus)
      refute ConsistencyLevel.valid?("strong")
    end
  end

  describe "default/0" do
    test "is a valid level" do
      assert ConsistencyLevel.valid?(ConsistencyLevel.default())
    end
  end

  describe "parse/1" do
    test "parses valid strings" do
      assert ConsistencyLevel.parse("strong") == {:ok, :strong}
      assert ConsistencyLevel.parse("eventual") == {:ok, :eventual}
      assert ConsistencyLevel.parse("causal") == {:ok, :causal}
    end

    test "passes through valid atoms" do
      assert ConsistencyLevel.parse(:strong) == {:ok, :strong}
    end

    test "rejects unknown input without creating atoms" do
      assert ConsistencyLevel.parse("nonsense") == {:error, :invalid_consistency}
      assert ConsistencyLevel.parse(:nope) == {:error, :invalid_consistency}
      assert ConsistencyLevel.parse(123) == {:error, :invalid_consistency}
    end
  end

  describe "stronger_than?/2" do
    test "strong dominates the weaker levels" do
      assert ConsistencyLevel.stronger_than?(:strong, :eventual)
      assert ConsistencyLevel.stronger_than?(:strong, :causal)
      assert ConsistencyLevel.stronger_than?(:causal, :eventual)
      refute ConsistencyLevel.stronger_than?(:eventual, :strong)
    end
  end
end
