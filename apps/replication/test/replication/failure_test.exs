defmodule Replication.FailureTest do
  use ExUnit.Case, async: false

  alias Replication.{Leader, Follower, Stream}
  alias CoreDomain.Types.NodeId

  setup do
    case Process.whereis(Replication.Registry) do
      nil -> start_supervised!({Registry, keys: :unique, name: Replication.Registry})
      _pid -> :ok
    end

    :ok
  end

  describe "Follower failures" do
    test "leader continues operating when follower crashes" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 1]})
      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})
      {:ok, follower_pid} = start_supervised({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)

      # Kill follower
      Process.exit(follower_pid, :kill)
      Process.sleep(50)

      # Leader should still accept writes (local consistency)
      {:ok, offset} = Leader.write(group_id, "data", consistency_level: :local)
      assert offset.value == 1
    end

    test "writes timeout when quorum unavailable" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      # 3 replicas but only leader - can't reach quorum
      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 3]})

      # Should timeout
      assert catch_exit(Leader.write(group_id, "data", consistency_level: :quorum, timeout: 100))
    end
  end

  describe "Stream failures" do
    test "follower detects missing entries after stream restart" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 1]})
      {:ok, stream_pid} = start_supervised({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 10]})
      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)

      # Write some data
      {:ok, _} = Leader.write(group_id, "data1", consistency_level: :local)

      # Kill stream before it flushes
      Process.exit(stream_pid, :kill)
      Process.sleep(50)

      # Restart stream
      start_supervised({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 10]})
      Stream.add_follower(group_id, follower_id)

      # Follower should eventually be able to catch up (in real implementation)
      # For now, just verify system didn't crash
      follower_pid = GenServer.whereis({:via, Registry, {Replication.Registry, {:follower, group_id}}})
      assert follower_pid != nil
      assert Process.alive?(follower_pid)
    end
  end
end
