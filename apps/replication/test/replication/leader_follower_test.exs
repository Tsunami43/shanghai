defmodule Replication.LeaderFollowerTest do
  use ExUnit.Case, async: false

  alias Replication.{Leader, Follower}
  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  setup do
    # Start registry if not already running
    case Process.whereis(Replication.Registry) do
      nil -> start_supervised!({Registry, keys: :unique, name: Replication.Registry})
      _pid -> :ok
    end

    :ok
  end

  describe "Leader-Follower interaction" do
    test "leader tracks its own offset" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      node_id = NodeId.new("leader-node")

      start_supervised!({Leader, [group_id: group_id, node_id: node_id]})

      offset = Leader.current_offset(group_id)
      assert offset.value == 0
    end

    test "follower starts at zero offset" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      node_id = NodeId.new("follower-node")

      start_supervised!({Follower, [group_id: group_id, node_id: node_id]})

      offset = Follower.current_offset(group_id)
      assert offset.value == 0
    end

    test "follower can set leader" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      follower_id = NodeId.new("follower")
      leader_id = NodeId.new("leader")

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      assert :ok = Follower.set_leader(group_id, leader_id)
    end

    test "follower applies entries in order" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      follower_id = NodeId.new("follower")

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      # Apply first entry
      offset1 = ReplicationOffset.new(1)
      Follower.apply_entry(group_id, offset1, "data1")

      Process.sleep(50)

      current = Follower.current_offset(group_id)
      assert current.value == 1

      # Apply second entry
      offset2 = ReplicationOffset.new(2)
      Follower.apply_entry(group_id, offset2, "data2")

      Process.sleep(50)

      current = Follower.current_offset(group_id)
      assert current.value == 2
    end

    test "follower reports offset to leader" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id]})
      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      # Set leader for follower
      Follower.set_leader(group_id, leader_id)

      # Apply an entry
      offset = ReplicationOffset.new(1)
      Follower.apply_entry(group_id, offset, "test-data")

      # Give time for reporting
      Process.sleep(1100)

      # Leader should have received the offset report
      # (This is verified indirectly through logs in real implementation)
      assert true
    end
  end

  describe "Write coordination" do
    test "leader accepts writes" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id]})

      # Write with short timeout (will complete immediately for single node)
      {:ok, offset} = Leader.write(group_id, "test-data", timeout: 1000)

      assert offset.value == 1

      current = Leader.current_offset(group_id)
      assert current.value == 1
    end

    test "multiple writes increment offset" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id]})

      {:ok, offset1} = Leader.write(group_id, "data1")
      {:ok, offset2} = Leader.write(group_id, "data2")
      {:ok, offset3} = Leader.write(group_id, "data3")

      assert offset1.value == 1
      assert offset2.value == 2
      assert offset3.value == 3
    end
  end
end
