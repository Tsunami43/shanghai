defmodule Replication.QuorumTest do
  use ExUnit.Case, async: true

  alias Replication.Quorum

  doctest Quorum

  test "size/1 is a strict majority, including even counts" do
    assert Quorum.size(1) == 1
    assert Quorum.size(2) == 2
    assert Quorum.size(3) == 2
    assert Quorum.size(4) == 3
    assert Quorum.size(6) == 4
  end

  test "satisfied?/2 is exact at the quorum boundary" do
    for n <- 1..7 do
      q = Quorum.size(n)
      assert Quorum.satisfied?(q, n)
      refute Quorum.satisfied?(q - 1, n)
    end
  end

  test "min_available/1 equals the quorum size" do
    for n <- 1..7, do: assert(Quorum.min_available(n) == Quorum.size(n))
  end

  test "max_failures/1 is replicas minus quorum" do
    assert Quorum.max_failures(1) == 0
    assert Quorum.max_failures(3) == 1
    assert Quorum.max_failures(4) == 1
    assert Quorum.max_failures(5) == 2
    assert Quorum.max_failures(7) == 3
  end

  test "percentage/1 reports quorum share" do
    assert Quorum.percentage(4) == 75.0
    assert Quorum.percentage(5) == 60.0
    assert Quorum.percentage(2) == 100.0
  end
end
