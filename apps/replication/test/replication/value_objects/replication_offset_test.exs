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

  describe "max_of/1" do
    test "returns the greatest offset in the list" do
      offsets = [ReplicationOffset.new(3), ReplicationOffset.new(9), ReplicationOffset.new(5)]
      assert ReplicationOffset.max_of(offsets) == ReplicationOffset.new(9)
    end
  end

  describe "min_of/1" do
    test "returns the smallest offset in the list" do
      offsets = [ReplicationOffset.new(3), ReplicationOffset.new(9), ReplicationOffset.new(5)]
      assert ReplicationOffset.min_of(offsets) == ReplicationOffset.new(3)
    end
  end

  describe "later/2 and earlier/2" do
    test "pick the greater/lesser offset" do
      a = ReplicationOffset.new(5)
      b = ReplicationOffset.new(15)

      assert ReplicationOffset.later(a, b) == b
      assert ReplicationOffset.later(b, a) == b
      assert ReplicationOffset.earlier(a, b) == a
      assert ReplicationOffset.earlier(b, a) == a
    end
  end

  describe "to_integer/1" do
    test "returns the raw value" do
      assert ReplicationOffset.to_integer(ReplicationOffset.new(7)) == 7
      assert ReplicationOffset.to_integer(ReplicationOffset.zero()) == 0
    end
  end

  describe "equal?/2" do
    test "compares offsets by value" do
      assert ReplicationOffset.equal?(ReplicationOffset.new(5), ReplicationOffset.new(5))
      refute ReplicationOffset.equal?(ReplicationOffset.new(5), ReplicationOffset.new(6))
    end
  end

  describe "initial?/1" do
    test "is true only for the zero offset" do
      assert ReplicationOffset.initial?(ReplicationOffset.zero())
      refute ReplicationOffset.initial?(ReplicationOffset.new(1))
    end
  end

  describe "between?/3" do
    test "checks inclusive range membership" do
      assert ReplicationOffset.between?(
               ReplicationOffset.new(5),
               ReplicationOffset.new(1),
               ReplicationOffset.new(10)
             )

      refute ReplicationOffset.between?(
               ReplicationOffset.new(11),
               ReplicationOffset.new(1),
               ReplicationOffset.new(10)
             )
    end
  end

  test "ahead?/2 is true when strictly greater" do
    assert ReplicationOffset.ahead?(ReplicationOffset.new(5), ReplicationOffset.new(3))
    refute ReplicationOffset.ahead?(ReplicationOffset.new(3), ReplicationOffset.new(3))
    refute ReplicationOffset.ahead?(ReplicationOffset.new(2), ReplicationOffset.new(3))
  end

  test "caught_up?/2 is true at or past the target" do
    assert ReplicationOffset.caught_up?(ReplicationOffset.new(3), ReplicationOffset.new(3))
    assert ReplicationOffset.caught_up?(ReplicationOffset.new(4), ReplicationOffset.new(3))
    refute ReplicationOffset.caught_up?(ReplicationOffset.new(2), ReplicationOffset.new(3))
  end

  test "delta/2 returns the signed difference b - a" do
    assert ReplicationOffset.delta(ReplicationOffset.new(3), ReplicationOffset.new(10)) == 7
    assert ReplicationOffset.delta(ReplicationOffset.new(10), ReplicationOffset.new(3)) == -7
    assert ReplicationOffset.delta(ReplicationOffset.new(5), ReplicationOffset.new(5)) == 0
  end

  test "to_string/1 renders a display form" do
    assert ReplicationOffset.to_string(ReplicationOffset.new(9)) == "Offset(9)"
    assert ReplicationOffset.to_string(ReplicationOffset.zero()) == "Offset(0)"
  end

  test "range/2 builds an inclusive list, empty when reversed" do
    assert ReplicationOffset.range(ReplicationOffset.new(2), ReplicationOffset.new(4))
           |> Enum.map(& &1.value) == [2, 3, 4]

    assert ReplicationOffset.range(ReplicationOffset.new(4), ReplicationOffset.new(2)) == []
  end

  test "clamp/3 constrains an offset to the range" do
    assert ReplicationOffset.clamp(
             ReplicationOffset.new(15),
             ReplicationOffset.new(0),
             ReplicationOffset.new(10)
           ).value ==
             10

    assert ReplicationOffset.clamp(
             ReplicationOffset.new(0),
             ReplicationOffset.new(3),
             ReplicationOffset.new(10)
           ).value ==
             3

    assert ReplicationOffset.clamp(
             ReplicationOffset.new(5),
             ReplicationOffset.new(0),
             ReplicationOffset.new(10)
           ).value ==
             5
  end

  test "catch_up_ratio/2 measures progress toward the target" do
    assert ReplicationOffset.catch_up_ratio(ReplicationOffset.new(5), ReplicationOffset.new(10)) ==
             0.5

    assert ReplicationOffset.catch_up_ratio(ReplicationOffset.new(10), ReplicationOffset.new(10)) ==
             1.0

    assert ReplicationOffset.catch_up_ratio(ReplicationOffset.new(12), ReplicationOffset.new(10)) ==
             1.0

    assert ReplicationOffset.catch_up_ratio(ReplicationOffset.new(0), ReplicationOffset.new(0)) ==
             1.0
  end

  test "distance/2 is the non-negative gap regardless of order" do
    assert ReplicationOffset.distance(ReplicationOffset.new(3), ReplicationOffset.new(10)).value ==
             7

    assert ReplicationOffset.distance(ReplicationOffset.new(10), ReplicationOffset.new(3)).value ==
             7

    assert ReplicationOffset.distance(ReplicationOffset.new(5), ReplicationOffset.new(5)).value ==
             0
  end

  test "sort/1 orders offsets ascending" do
    offsets = [ReplicationOffset.new(3), ReplicationOffset.new(1), ReplicationOffset.new(2)]
    assert Enum.map(ReplicationOffset.sort(offsets), & &1.value) == [1, 2, 3]
  end

  test "pending?/2 is the complement of caught_up?/2" do
    assert ReplicationOffset.pending?(ReplicationOffset.new(2), ReplicationOffset.new(5))
    refute ReplicationOffset.pending?(ReplicationOffset.new(5), ReplicationOffset.new(5))
    refute ReplicationOffset.pending?(ReplicationOffset.new(6), ReplicationOffset.new(5))
  end

  test "positive?/1 is the inverse of initial?/1" do
    assert ReplicationOffset.positive?(ReplicationOffset.new(1))
    refute ReplicationOffset.positive?(ReplicationOffset.zero())
  end

  test "span/1 returns the min and max offsets" do
    {lo, hi} =
      ReplicationOffset.span([
        ReplicationOffset.new(3),
        ReplicationOffset.new(1),
        ReplicationOffset.new(7)
      ])

    assert lo.value == 1
    assert hi.value == 7
  end

  test "differ?/2 is the inverse of equal?/2" do
    refute ReplicationOffset.differ?(ReplicationOffset.new(5), ReplicationOffset.new(5))
    assert ReplicationOffset.differ?(ReplicationOffset.new(5), ReplicationOffset.new(6))
  end

  test "decrement/1 steps back by one, clamping at zero" do
    assert ReplicationOffset.decrement(ReplicationOffset.new(5)).value == 4
    assert ReplicationOffset.decrement(ReplicationOffset.zero()).value == 0
  end

  test "parse/1 validates before building an offset" do
    assert {:ok, %ReplicationOffset{value: 5}} = ReplicationOffset.parse(5)
    assert {:error, :invalid} = ReplicationOffset.parse(-1)
    assert {:error, :invalid} = ReplicationOffset.parse("x")
  end

  test "rewind/2 steps back by amount, clamping at zero" do
    assert ReplicationOffset.rewind(ReplicationOffset.new(10), 3).value == 7
    assert ReplicationOffset.rewind(ReplicationOffset.new(10), 99).value == 0
  end

  test "at_or_before?/2 and at_or_after?/2 are inclusive comparisons" do
    a = ReplicationOffset.new(5)

    assert ReplicationOffset.at_or_before?(a, ReplicationOffset.new(5))
    assert ReplicationOffset.at_or_before?(a, ReplicationOffset.new(6))
    refute ReplicationOffset.at_or_before?(a, ReplicationOffset.new(4))

    assert ReplicationOffset.at_or_after?(a, ReplicationOffset.new(5))
    assert ReplicationOffset.at_or_after?(a, ReplicationOffset.new(4))
    refute ReplicationOffset.at_or_after?(a, ReplicationOffset.new(6))
  end
end
