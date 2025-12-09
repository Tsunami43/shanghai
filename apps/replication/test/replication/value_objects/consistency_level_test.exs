defmodule Replication.ValueObjects.ConsistencyLevelTest do
  use ExUnit.Case, async: true

  alias Replication.ValueObjects.ConsistencyLevel

  describe "new/1" do
    test "creates local consistency level" do
      level = ConsistencyLevel.new(:local)
      assert level.level == :local
    end

    test "creates quorum consistency level" do
      level = ConsistencyLevel.new(:quorum)
      assert level.level == :quorum
    end

    test "creates leader consistency level" do
      level = ConsistencyLevel.new(:leader)
      assert level.level == :leader
    end
  end

  describe "default/0" do
    test "returns quorum as default" do
      level = ConsistencyLevel.default()
      assert level.level == :quorum
    end
  end

  describe "requires_quorum?/1" do
    test "returns true for quorum level" do
      level = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.requires_quorum?(level) == true
    end

    test "returns false for local level" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.requires_quorum?(level) == false
    end

    test "returns false for leader level" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.requires_quorum?(level) == false
    end
  end

  describe "requires_leader_only?/1" do
    test "returns true for leader level" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.requires_leader_only?(level) == true
    end

    test "returns false for local level" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.requires_leader_only?(level) == false
    end

    test "returns false for quorum level" do
      level = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.requires_leader_only?(level) == false
    end
  end

  describe "local?/1" do
    test "returns true for local level" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.local?(level) == true
    end

    test "returns false for quorum level" do
      level = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.local?(level) == false
    end

    test "returns false for leader level" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.local?(level) == false
    end
  end

  describe "required_acks/2" do
    test "local level requires 1 ack" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.required_acks(level, 3) == 1
      assert ConsistencyLevel.required_acks(level, 5) == 1
    end

    test "leader level requires 1 ack" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.required_acks(level, 3) == 1
      assert ConsistencyLevel.required_acks(level, 5) == 1
    end

    test "quorum level requires majority" do
      level = ConsistencyLevel.new(:quorum)

      # 3 replicas -> need 2
      assert ConsistencyLevel.required_acks(level, 3) == 2

      # 5 replicas -> need 3
      assert ConsistencyLevel.required_acks(level, 5) == 3

      # 7 replicas -> need 4
      assert ConsistencyLevel.required_acks(level, 7) == 4

      # 1 replica -> need 1
      assert ConsistencyLevel.required_acks(level, 1) == 1

      # 2 replicas -> need 2
      assert ConsistencyLevel.required_acks(level, 2) == 2
    end
  end

  describe "to_string/1" do
    test "converts local to string" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.to_string(level) == "local"
    end

    test "converts quorum to string" do
      level = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.to_string(level) == "quorum"
    end

    test "converts leader to string" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.to_string(level) == "leader"
    end
  end

  describe "parse/1" do
    test "parses atom values" do
      assert {:ok, %ConsistencyLevel{level: :local}} = ConsistencyLevel.parse(:local)
      assert {:ok, %ConsistencyLevel{level: :quorum}} = ConsistencyLevel.parse(:quorum)
      assert {:ok, %ConsistencyLevel{level: :leader}} = ConsistencyLevel.parse(:leader)
    end

    test "parses string values" do
      assert {:ok, %ConsistencyLevel{level: :local}} = ConsistencyLevel.parse("local")
      assert {:ok, %ConsistencyLevel{level: :quorum}} = ConsistencyLevel.parse("quorum")
      assert {:ok, %ConsistencyLevel{level: :leader}} = ConsistencyLevel.parse("leader")
    end

    test "returns error for invalid values" do
      assert {:error, :invalid_consistency_level} = ConsistencyLevel.parse(:invalid)
      assert {:error, :invalid_consistency_level} = ConsistencyLevel.parse("invalid")
      assert {:error, :invalid_consistency_level} = ConsistencyLevel.parse(123)
    end
  end

  describe "all/0 and equal?/2" do
    test "all/0 lists every level as a struct" do
      levels = Enum.map(ConsistencyLevel.all(), & &1.level)
      assert levels == [:local, :quorum, :leader]
    end

    test "equal?/2 compares by level" do
      assert ConsistencyLevel.equal?(ConsistencyLevel.new(:quorum), ConsistencyLevel.new(:quorum))
      refute ConsistencyLevel.equal?(ConsistencyLevel.new(:quorum), ConsistencyLevel.new(:leader))
    end
  end

  describe "rank/1 and compare/2" do
    test "rank orders local < quorum < leader" do
      assert ConsistencyLevel.rank(ConsistencyLevel.new(:local)) <
               ConsistencyLevel.rank(ConsistencyLevel.new(:quorum))

      assert ConsistencyLevel.rank(ConsistencyLevel.new(:quorum)) <
               ConsistencyLevel.rank(ConsistencyLevel.new(:leader))
    end

    test "compare returns :lt, :eq, :gt by strength" do
      assert ConsistencyLevel.compare(ConsistencyLevel.new(:local), ConsistencyLevel.new(:leader)) ==
               :lt

      assert ConsistencyLevel.compare(ConsistencyLevel.new(:leader), ConsistencyLevel.new(:local)) ==
               :gt

      assert ConsistencyLevel.compare(
               ConsistencyLevel.new(:quorum),
               ConsistencyLevel.new(:quorum)
             ) ==
               :eq
    end
  end

  describe "stronger/2 and weaker/2" do
    test "pick by durability strength regardless of order" do
      local = ConsistencyLevel.new(:local)
      leader = ConsistencyLevel.new(:leader)

      assert ConsistencyLevel.stronger(local, leader) == leader
      assert ConsistencyLevel.stronger(leader, local) == leader
      assert ConsistencyLevel.weaker(local, leader) == local
      assert ConsistencyLevel.weaker(leader, local) == local
    end

    test "ties return the first argument" do
      quorum = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.stronger(quorum, quorum) == quorum
      assert ConsistencyLevel.weaker(quorum, quorum) == quorum
    end
  end

  describe "ordered/0" do
    test "lists levels from weakest to strongest" do
      assert Enum.map(ConsistencyLevel.ordered(), & &1.level) == [:local, :quorum, :leader]
    end
  end

  describe "parse!/1" do
    test "returns the level or raises" do
      assert %ConsistencyLevel{level: :quorum} = ConsistencyLevel.parse!("quorum")
      assert %ConsistencyLevel{level: :leader} = ConsistencyLevel.parse!(:leader)
      assert_raise ArgumentError, fn -> ConsistencyLevel.parse!("nope") end
    end
  end

  describe "waits_for_peers?/1" do
    test "is false only for local" do
      refute ConsistencyLevel.waits_for_peers?(ConsistencyLevel.new(:local))
      assert ConsistencyLevel.waits_for_peers?(ConsistencyLevel.new(:quorum))
      assert ConsistencyLevel.waits_for_peers?(ConsistencyLevel.new(:leader))
    end
  end

  describe "durable?/1" do
    test "is false only for local" do
      refute ConsistencyLevel.durable?(ConsistencyLevel.new(:local))
      assert ConsistencyLevel.durable?(ConsistencyLevel.new(:quorum))
      assert ConsistencyLevel.durable?(ConsistencyLevel.new(:leader))
    end
  end

  describe "at_least_levels/1 and at_most_levels/1" do
    test "filter levels around the given durability" do
      quorum = ConsistencyLevel.new(:quorum)

      assert ConsistencyLevel.at_least_levels(quorum) ==
               [ConsistencyLevel.new(:quorum), ConsistencyLevel.new(:leader)]

      assert ConsistencyLevel.at_most_levels(quorum) ==
               [ConsistencyLevel.new(:local), ConsistencyLevel.new(:quorum)]
    end
  end

  describe "at_least?/2 and at_most?/2" do
    test "compare durability inclusively" do
      local = ConsistencyLevel.new(:local)
      quorum = ConsistencyLevel.new(:quorum)
      leader = ConsistencyLevel.new(:leader)

      assert ConsistencyLevel.at_least?(leader, quorum)
      assert ConsistencyLevel.at_least?(quorum, quorum)
      refute ConsistencyLevel.at_least?(local, quorum)

      assert ConsistencyLevel.at_most?(local, quorum)
      assert ConsistencyLevel.at_most?(quorum, quorum)
      refute ConsistencyLevel.at_most?(leader, quorum)
    end
  end
end
