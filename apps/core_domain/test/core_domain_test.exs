defmodule CoreDomainTest do
  use ExUnit.Case

  alias CoreDomain.Types.LogSequenceNumber
  alias CoreDomain.Types.NodeId
  alias CoreDomain.ValueObjects.ConsistencyLevel

  describe "LogSequenceNumber" do
    test "creates and compares LSNs" do
      lsn1 = LogSequenceNumber.new(1)
      lsn2 = LogSequenceNumber.new(2)

      assert LogSequenceNumber.compare(lsn1, lsn2) == :lt
      assert LogSequenceNumber.compare(lsn2, lsn1) == :gt
      assert LogSequenceNumber.compare(lsn1, lsn1) == :eq
    end

    test "increments LSN" do
      lsn = LogSequenceNumber.new(5)
      next_lsn = LogSequenceNumber.increment(lsn)

      assert next_lsn.value == 6
    end
  end

  describe "NodeId" do
    test "generates unique node IDs" do
      id1 = NodeId.generate()
      id2 = NodeId.generate()

      refute NodeId.equal?(id1, id2)
    end
  end

  describe "ConsistencyLevel" do
    test "validates consistency levels" do
      assert ConsistencyLevel.valid?(:strong)
      assert ConsistencyLevel.valid?(:eventual)
      assert ConsistencyLevel.valid?(:causal)
      refute ConsistencyLevel.valid?(:invalid)
    end

    test "compares consistency levels" do
      assert ConsistencyLevel.stronger_than?(:strong, :eventual)
      assert ConsistencyLevel.stronger_than?(:causal, :eventual)
      refute ConsistencyLevel.stronger_than?(:eventual, :strong)
    end
  end
end
