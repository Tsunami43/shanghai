defmodule Replication.ValueObjects.ReplicationOffsetTest do
  use ExUnit.Case, async: true

  alias Replication.ValueObjects.ReplicationOffset

  describe "new/1" do
    test "creates offset with given value" do
      offset = ReplicationOffset.new(42)
      assert offset.value == 42
    end

    test "creates zero offset" do
      offset = ReplicationOffset.zero()
      assert offset.value == 0
    end
  end

  describe "increment/1" do
    test "increments offset by 1" do
      offset = ReplicationOffset.new(10)
      incremented = ReplicationOffset.increment(offset)
      assert incremented.value == 11
    end
  end

  describe "advance/2" do
    test "advances offset by given amount" do
      offset = ReplicationOffset.new(10)
      advanced = ReplicationOffset.advance(offset, 5)
      assert advanced.value == 15
    end
  end

  describe "compare/2" do
    test "returns :lt when first is less than second" do
      offset1 = ReplicationOffset.new(5)
      offset2 = ReplicationOffset.new(10)
      assert ReplicationOffset.compare(offset1, offset2) == :lt
    end

    test "returns :gt when first is greater than second" do
      offset1 = ReplicationOffset.new(10)
      offset2 = ReplicationOffset.new(5)
      assert ReplicationOffset.compare(offset1, offset2) == :gt
    end

    test "returns :eq when offsets are equal" do
      offset1 = ReplicationOffset.new(10)
      offset2 = ReplicationOffset.new(10)
      assert ReplicationOffset.compare(offset1, offset2) == :eq
    end
  end

  describe "behind?/2" do
    test "returns true when first is behind second" do
      offset1 = ReplicationOffset.new(5)
      offset2 = ReplicationOffset.new(10)
      assert ReplicationOffset.behind?(offset1, offset2)
    end

    test "returns false when first is ahead" do
      offset1 = ReplicationOffset.new(10)
      offset2 = ReplicationOffset.new(5)
      refute ReplicationOffset.behind?(offset1, offset2)
    end
  end

  describe "lag/2" do
    test "calculates lag between current and target" do
      current = ReplicationOffset.new(5)
      target = ReplicationOffset.new(15)
      assert ReplicationOffset.lag(current, target) == 10
    end

    test "returns 0 when current is ahead of target" do
      current = ReplicationOffset.new(15)
      target = ReplicationOffset.new(5)
      assert ReplicationOffset.lag(current, target) == 0
    end

    test "returns 0 when offsets are equal" do
      offset = ReplicationOffset.new(10)
      assert ReplicationOffset.lag(offset, offset) == 0
    end
  end
end
