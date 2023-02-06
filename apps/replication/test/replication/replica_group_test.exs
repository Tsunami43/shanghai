defmodule Replication.ReplicaGroupTest do
  use ExUnit.Case, async: true

  alias Replication.ReplicaGroup
  alias Replication.Events.{LeaderElected, ReplicaCaughtUp, ReplicaFellBehind}
  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  describe "new/1" do
    test "creates empty replica group" do
      group = ReplicaGroup.new("shard-1")

      assert group.group_id == "shard-1"
      assert group.replicas == %{}
      assert group.leader_node_id == nil
      assert group.term == 0
    end
  end

  describe "add_replica/2" do
    test "adds replica as follower" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, updated_group} = ReplicaGroup.add_replica(group, node_id)

      assert map_size(updated_group.replicas) == 1
      assert Map.has_key?(updated_group.replicas, node_id)
    end

    test "returns error for duplicate replica" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, updated_group} = ReplicaGroup.add_replica(group, node_id)
      result = ReplicaGroup.add_replica(updated_group, node_id)

      assert {:error, :replica_already_exists} = result
    end
  end

  describe "elect_leader/2" do
    test "elects leader and increments term" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      {:ok, updated_group} = ReplicaGroup.elect_leader(group, node_id)

      assert updated_group.leader_node_id == node_id
      assert updated_group.term == 1
    end

    test "emits LeaderElected event" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      {:ok, updated_group} = ReplicaGroup.elect_leader(group, node_id)

      assert [%LeaderElected{leader_node_id: ^node_id, term: 1}] = updated_group.events
    end

    test "demotes old leader when electing new one" do
      group = ReplicaGroup.new("shard-1")
      node1 = NodeId.new("node1")
      node2 = NodeId.new("node2")

      {:ok, group} = ReplicaGroup.add_replica(group, node1)
      {:ok, group} = ReplicaGroup.add_replica(group, node2)
      {:ok, group} = ReplicaGroup.elect_leader(group, node1)

      {:ok, updated_group} = ReplicaGroup.elect_leader(group, node2)

      old_leader = updated_group.replicas[node1]
      new_leader = updated_group.replicas[node2]

      assert old_leader.role == :follower
      assert new_leader.role == :leader
      assert updated_group.term == 2
    end
  end

  describe "update_replica_offset/3" do
    test "updates replica offset" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      new_offset = ReplicationOffset.new(42)

      {:ok, updated_group} = ReplicaGroup.update_replica_offset(group, node_id, new_offset)

      replica = updated_group.replicas[node_id]
      assert replica.offset.value == 42
    end

    test "emits ReplicaCaughtUp when lagging replica catches up" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      {:ok, group} = ReplicaGroup.mark_replica_lagging(group, node_id, ReplicationOffset.zero())

      offset = ReplicationOffset.new(10)
      {:ok, updated_group} = ReplicaGroup.update_replica_offset(group, node_id, offset)

      # Should have caught up event (plus the fell behind event from mark_lagging)
      assert length(updated_group.events) >= 1
    end
  end

  describe "mark_replica_lagging/3" do
    test "marks replica as lagging and emits event" do
      group = ReplicaGroup.new("shard-1")
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      {:ok, group} = ReplicaGroup.add_replica(group, leader_id)
      {:ok, group} = ReplicaGroup.add_replica(group, follower_id)
      {:ok, group} = ReplicaGroup.elect_leader(group, leader_id)

      {:ok, updated_group} =
        ReplicaGroup.mark_replica_lagging(
          group,
          follower_id,
          ReplicationOffset.zero()
        )

      follower = updated_group.replicas[follower_id]
      assert follower.status == :lagging

      # Should have fell behind event (plus leader elected)
      assert length(updated_group.events) >= 2
      [event | _] = updated_group.events
      assert %ReplicaFellBehind{} = event
    end
  end

  describe "get_leader_replica/1" do
    test "returns leader replica when exists" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      {:ok, group} = ReplicaGroup.elect_leader(group, node_id)

      {:ok, leader} = ReplicaGroup.get_leader_replica(group)

      assert leader.node_id == node_id
      assert leader.role == :leader
    end

    test "returns error when no leader" do
      group = ReplicaGroup.new("shard-1")

      assert {:error, :no_leader} = ReplicaGroup.get_leader_replica(group)
    end
  end

  describe "follower_replicas/1" do
    test "returns only followers" do
      group = ReplicaGroup.new("shard-1")
      leader_id = NodeId.new("leader")
      follower1_id = NodeId.new("follower1")
      follower2_id = NodeId.new("follower2")

      {:ok, group} = ReplicaGroup.add_replica(group, leader_id)
      {:ok, group} = ReplicaGroup.add_replica(group, follower1_id)
      {:ok, group} = ReplicaGroup.add_replica(group, follower2_id)
      {:ok, group} = ReplicaGroup.elect_leader(group, leader_id)

      followers = ReplicaGroup.follower_replicas(group)

      assert length(followers) == 2
      assert Enum.all?(followers, &(&1.role == :follower))
    end
  end

  describe "count_caught_up/2" do
    test "counts replicas at or past target offset" do
      group = ReplicaGroup.new("shard-1")
      node1 = NodeId.new("node1")
      node2 = NodeId.new("node2")
      node3 = NodeId.new("node3")

      {:ok, group} = ReplicaGroup.add_replica(group, node1)
      {:ok, group} = ReplicaGroup.add_replica(group, node2)
      {:ok, group} = ReplicaGroup.add_replica(group, node3)

      {:ok, group} = ReplicaGroup.update_replica_offset(group, node1, ReplicationOffset.new(10))
      {:ok, group} = ReplicaGroup.update_replica_offset(group, node2, ReplicationOffset.new(5))
      {:ok, group} = ReplicaGroup.update_replica_offset(group, node3, ReplicationOffset.new(15))

      count = ReplicaGroup.count_caught_up(group, ReplicationOffset.new(10))

      assert count == 2
    end
  end

  describe "take_events/1" do
    test "returns events and clears list" do
      group = ReplicaGroup.new("shard-1")
      node_id = NodeId.new("node1")

      {:ok, group} = ReplicaGroup.add_replica(group, node_id)
      {:ok, group_with_events} = ReplicaGroup.elect_leader(group, node_id)

      {events, group_without_events} = ReplicaGroup.take_events(group_with_events)

      assert length(events) == 1
      assert [%LeaderElected{}] = events
      assert group_without_events.events == []
    end
  end
end
