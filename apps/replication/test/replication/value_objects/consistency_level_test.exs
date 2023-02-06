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

  describe "is_local?/1" do
    test "returns true for local level" do
      level = ConsistencyLevel.new(:local)
      assert ConsistencyLevel.is_local?(level) == true
    end

    test "returns false for quorum level" do
      level = ConsistencyLevel.new(:quorum)
      assert ConsistencyLevel.is_local?(level) == false
    end

    test "returns false for leader level" do
      level = ConsistencyLevel.new(:leader)
      assert ConsistencyLevel.is_local?(level) == false
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
end
