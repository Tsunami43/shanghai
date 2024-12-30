defmodule CoreDomain.Types.LogSequenceNumberTest do
  use ExUnit.Case, async: true

  alias CoreDomain.Types.LogSequenceNumber, as: LSN

  doctest LSN

  test "new/1 wraps a non-negative integer" do
    assert LSN.new(0).value == 0
    assert LSN.new(42).value == 42
  end

  test "zero/0 is the starting LSN" do
    assert LSN.zero() == LSN.new(0)
  end

  test "compare/2 totally orders LSNs" do
    assert LSN.compare(LSN.new(1), LSN.new(2)) == :lt
    assert LSN.compare(LSN.new(2), LSN.new(1)) == :gt
    assert LSN.compare(LSN.new(7), LSN.new(7)) == :eq
  end

  test "increment/1 and next/1 advance by one" do
    assert LSN.increment(LSN.new(4)) == LSN.new(5)
    assert LSN.next(LSN.new(4)) == LSN.new(5)
  end

  test "advance/2 moves forward by n" do
    assert LSN.advance(LSN.new(10), 0) == LSN.new(10)
    assert LSN.advance(LSN.new(10), 5) == LSN.new(15)
  end

  test "max_of/1 returns the greatest LSN in the list" do
    assert LSN.max_of([LSN.new(3), LSN.new(9), LSN.new(5)]) == LSN.new(9)
  end

  test "min_of/1 returns the smallest LSN in the list" do
    assert LSN.min_of([LSN.new(3), LSN.new(9), LSN.new(5)]) == LSN.new(3)
  end

  test "initial?/1 is true only for the zero LSN" do
    assert LSN.initial?(LSN.zero())
    refute LSN.initial?(LSN.new(1))
  end

  test "later/2 and earlier/2 pick the greater/lesser LSN" do
    a = LSN.new(3)
    b = LSN.new(7)

    assert LSN.later(a, b) == b
    assert LSN.later(b, a) == b
    assert LSN.earlier(a, b) == a
    assert LSN.earlier(b, a) == a
    assert LSN.later(a, a) == a
  end

  test "to_integer/1 returns the raw value" do
    assert LSN.to_integer(LSN.new(9)) == 9
    assert LSN.to_integer(LSN.zero()) == 0
  end

  test "distance/2 measures how far b is ahead of a" do
    assert LSN.distance(LSN.new(3), LSN.new(10)) == 7
    assert LSN.distance(LSN.new(10), LSN.new(3)) == 0
    assert LSN.distance(LSN.new(5), LSN.new(5)) == 0
  end

  test "between?/3 checks inclusive range membership" do
    assert LSN.between?(LSN.new(5), LSN.new(1), LSN.new(10))
    assert LSN.between?(LSN.new(1), LSN.new(1), LSN.new(10))
    assert LSN.between?(LSN.new(10), LSN.new(1), LSN.new(10))
    refute LSN.between?(LSN.new(11), LSN.new(1), LSN.new(10))
  end

  test "predecessor/1 returns the prior LSN, nil at zero" do
    assert LSN.predecessor(LSN.new(5)).value == 4
    assert LSN.predecessor(LSN.zero()) == nil
  end

  test "contiguous?/2 detects an adjacent successor" do
    assert LSN.contiguous?(LSN.new(4), LSN.new(5))
    refute LSN.contiguous?(LSN.new(4), LSN.new(6))
    refute LSN.contiguous?(LSN.new(4), LSN.new(4))
  end

  test "to_string/1 renders a display form" do
    assert LSN.to_string(LSN.new(7)) == "LSN(7)"
    assert LSN.to_string(LSN.zero()) == "LSN(0)"
  end

  test "range/2 builds an inclusive list, empty when reversed" do
    assert LSN.range(LSN.new(2), LSN.new(4)) |> Enum.map(& &1.value) == [2, 3, 4]
    assert LSN.range(LSN.new(5), LSN.new(5)) |> Enum.map(& &1.value) == [5]
    assert LSN.range(LSN.new(5), LSN.new(2)) == []
  end

  test "diff/2 returns the signed difference b - a" do
    assert LSN.diff(LSN.new(3), LSN.new(10)) == 7
    assert LSN.diff(LSN.new(10), LSN.new(3)) == -7
    assert LSN.diff(LSN.new(4), LSN.new(4)) == 0
  end

  test "clamp/3 constrains an LSN to the range" do
    assert LSN.clamp(LSN.new(15), LSN.new(0), LSN.new(10)).value == 10
    assert LSN.clamp(LSN.new(0), LSN.new(3), LSN.new(10)).value == 3
    assert LSN.clamp(LSN.new(5), LSN.new(0), LSN.new(10)).value == 5
  end

  test "gap/2 counts the LSNs missing between two" do
    assert LSN.gap(LSN.new(3), LSN.new(7)) == 3
    assert LSN.gap(LSN.new(3), LSN.new(4)) == 0
    assert LSN.gap(LSN.new(5), LSN.new(5)) == 0
    assert LSN.gap(LSN.new(7), LSN.new(3)) == 0
  end

  test "sort/1 orders LSNs ascending" do
    lsns = [LSN.new(3), LSN.new(1), LSN.new(2)]
    assert Enum.map(LSN.sort(lsns), & &1.value) == [1, 2, 3]
  end

  test "sort_uniq/1 sorts and drops duplicates by value" do
    lsns = [LSN.new(3), LSN.new(1), LSN.new(3), LSN.new(2)]
    assert Enum.map(LSN.sort_uniq(lsns), & &1.value) == [1, 2, 3]
  end

  test "after?/2 and before?/2 compare LSNs" do
    assert LSN.after?(LSN.new(5), LSN.new(3))
    refute LSN.after?(LSN.new(3), LSN.new(5))
    refute LSN.after?(LSN.new(3), LSN.new(3))

    assert LSN.before?(LSN.new(3), LSN.new(5))
    refute LSN.before?(LSN.new(5), LSN.new(3))
    refute LSN.before?(LSN.new(3), LSN.new(3))
  end

  test "positive?/1 is the inverse of initial?/1" do
    assert LSN.positive?(LSN.new(1))
    refute LSN.positive?(LSN.zero())
    assert LSN.positive?(LSN.new(5)) == not LSN.initial?(LSN.new(5))
  end

  test "span/1 returns the min and max LSNs" do
    {lo, hi} = LSN.span([LSN.new(3), LSN.new(1), LSN.new(7), LSN.new(2)])
    assert lo.value == 1
    assert hi.value == 7
  end

  test "increasing?/1 detects a strictly increasing sequence" do
    assert LSN.increasing?([LSN.new(1), LSN.new(2), LSN.new(5)])
    refute LSN.increasing?([LSN.new(1), LSN.new(1)])
    refute LSN.increasing?([LSN.new(3), LSN.new(2)])
    assert LSN.increasing?([LSN.new(9)])
    assert LSN.increasing?([])
  end

  test "both_initial?/2 is true only when both LSNs are zero" do
    assert LSN.both_initial?(LSN.zero(), LSN.zero())
    refute LSN.both_initial?(LSN.zero(), LSN.new(1))
    refute LSN.both_initial?(LSN.new(1), LSN.new(1))
  end

  test "decrement/1 steps back by one, clamping at zero" do
    assert LSN.decrement(LSN.new(5)).value == 4
    assert LSN.decrement(LSN.zero()).value == 0
  end
end
