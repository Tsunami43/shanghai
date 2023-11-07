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

  test "later/2 and earlier/2 pick the greater/lesser LSN" do
    a = LSN.new(3)
    b = LSN.new(7)

    assert LSN.later(a, b) == b
    assert LSN.later(b, a) == b
    assert LSN.earlier(a, b) == a
    assert LSN.earlier(b, a) == a
    assert LSN.later(a, a) == a
  end
end
