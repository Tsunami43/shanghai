defmodule Replication.ConsistencyTest do
  use ExUnit.Case, async: false

  alias Replication.{Leader, Follower, Stream}
  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  setup do
    case Process.whereis(Replication.Registry) do
      nil -> start_supervised!({Registry, keys: :unique, name: Replication.Registry})
      _pid -> :ok
    end

    :ok
  end

  describe "Local consistency level" do
    test "completes immediately without waiting for followers" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 3]})

      # Local write should complete immediately with just leader ack
      start_time = System.monotonic_time(:millisecond)
      {:ok, offset} = Leader.write(group_id, "data", consistency_level: :local, timeout: 100)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert offset.value == 1
      # Should complete very quickly since no followers needed
      assert elapsed < 50
    end
  end

  describe "Leader consistency level" do
    test "requires only leader acknowledgment" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 3]})

      {:ok, offset} = Leader.write(group_id, "data", consistency_level: :leader, timeout: 100)

      assert offset.value == 1
    end
  end

  describe "Quorum consistency level" do
    test "requires majority acknowledgment" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      # 2 replicas, quorum = 2
      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 2]})
      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 1]})
      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)
      Follower.set_leader(group_id, leader_id)

      # Should wait for follower ack
      {:ok, offset} = Leader.write(group_id, "data", consistency_level: :quorum, timeout: 500)

      assert offset.value == 1

      # Verify follower received the entry
      Process.sleep(100)
      follower_offset = Follower.current_offset(group_id)
      assert follower_offset.value == 1
    end

    test "times out if quorum not reached" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      # 3 replicas but no followers - can't reach quorum
      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 3]})

      # Should timeout waiting for quorum (2 acks needed, only 1 from leader)
      assert catch_exit(Leader.write(group_id, "data", consistency_level: :quorum, timeout: 100))
    end
  end

  describe "Mixed consistency levels" do
    test "can use different levels for different writes" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 1]})

      # Fast local write
      {:ok, offset1} = Leader.write(group_id, "data1", consistency_level: :local)

      # Leader write
      {:ok, offset2} = Leader.write(group_id, "data2", consistency_level: :leader)

      # Quorum write (same as leader for single replica)
      {:ok, offset3} = Leader.write(group_id, "data3", consistency_level: :quorum)

      assert offset1.value == 1
      assert offset2.value == 2
      assert offset3.value == 3
    end
  end
end
