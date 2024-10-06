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

  describe "stronger/2" do
    test "returns the stronger level regardless of argument order" do
      assert ConsistencyLevel.stronger(:eventual, :strong) == :strong
      assert ConsistencyLevel.stronger(:strong, :eventual) == :strong
      assert ConsistencyLevel.stronger(:causal, :eventual) == :causal
      assert ConsistencyLevel.stronger(:strong, :strong) == :strong
    end
  end

  describe "weaker/2" do
    test "returns the weaker level regardless of argument order" do
      assert ConsistencyLevel.weaker(:strong, :eventual) == :eventual
      assert ConsistencyLevel.weaker(:eventual, :strong) == :eventual
      assert ConsistencyLevel.weaker(:causal, :eventual) == :eventual
      assert ConsistencyLevel.weaker(:strong, :strong) == :strong
    end
  end

  describe "rank/1 and compare/2" do
    test "rank orders eventual < causal < strong" do
      assert ConsistencyLevel.rank(:eventual) < ConsistencyLevel.rank(:causal)
      assert ConsistencyLevel.rank(:causal) < ConsistencyLevel.rank(:strong)
    end

    test "compare returns :lt, :eq, :gt by strength" do
      assert ConsistencyLevel.compare(:eventual, :strong) == :lt
      assert ConsistencyLevel.compare(:strong, :eventual) == :gt
      assert ConsistencyLevel.compare(:causal, :causal) == :eq
    end
  end

  describe "strongest/0 and weakest/0" do
    test "return the extremes of the ordering" do
      assert ConsistencyLevel.strongest() == :strong
      assert ConsistencyLevel.weakest() == :eventual

      assert ConsistencyLevel.rank(ConsistencyLevel.strongest()) ==
               Enum.max(Enum.map(ConsistencyLevel.all(), &ConsistencyLevel.rank/1))

      assert ConsistencyLevel.rank(ConsistencyLevel.weakest()) ==
               Enum.min(Enum.map(ConsistencyLevel.all(), &ConsistencyLevel.rank/1))
    end
  end

  describe "ordered/0" do
    test "lists levels from weakest to strongest" do
      assert ConsistencyLevel.ordered() == [:eventual, :causal, :strong]
    end
  end

  describe "weaker_than?/2 and at_least?/2" do
    test "weaker_than? is the inverse of stronger_than?" do
      assert ConsistencyLevel.weaker_than?(:eventual, :strong)
      refute ConsistencyLevel.weaker_than?(:strong, :eventual)
      refute ConsistencyLevel.weaker_than?(:strong, :strong)
    end

    test "at_least? accepts stronger or equal levels" do
      assert ConsistencyLevel.at_least?(:strong, :eventual)
      assert ConsistencyLevel.at_least?(:strong, :strong)
      refute ConsistencyLevel.at_least?(:eventual, :strong)
    end
  end

  describe "strongest_of/1 and weakest_of/1" do
    test "reduce a list to its extreme level" do
      assert ConsistencyLevel.strongest_of([:eventual, :strong, :causal]) == :strong
      assert ConsistencyLevel.weakest_of([:strong, :causal, :eventual]) == :eventual
      assert ConsistencyLevel.strongest_of([:causal]) == :causal
    end
  end
end
