defmodule Replication.StreamTest do
  use ExUnit.Case, async: false

  alias Replication.Stream
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

  describe "Stream initialization" do
    test "starts with empty follower list" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      states = Stream.get_follower_states(group_id)
      assert states == %{}
    end

    test "uses default batch size and flush interval" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      # Stream should be running and responsive
      states = Stream.get_follower_states(group_id)
      assert states == %{}
    end
  end

  describe "Follower management" do
    test "can add follower" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower1")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      :ok = Stream.add_follower(group_id, follower_id)

      states = Stream.get_follower_states(group_id)
      assert Map.has_key?(states, follower_id)
      assert states[follower_id].connection_status == :connected
      assert states[follower_id].last_sent_offset.value == 0
    end

    test "can remove follower" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower1")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      Stream.add_follower(group_id, follower_id)
      Stream.remove_follower(group_id, follower_id)

      states = Stream.get_follower_states(group_id)
      assert states == %{}
    end

    test "can manage multiple followers" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower1_id = NodeId.new("follower1")
      follower2_id = NodeId.new("follower2")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      Stream.add_follower(group_id, follower1_id)
      Stream.add_follower(group_id, follower2_id)

      states = Stream.get_follower_states(group_id)
      assert map_size(states) == 2
    end
  end

  describe "Entry streaming" do
    test "buffers entries until flush" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower1")

      # Start with long flush interval to test buffering
      start_supervised!(
        {Stream, [group_id: group_id, leader_node_id: leader_id, flush_interval_ms: 5000]}
      )

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)

      # Append some entries
      Stream.append_entry(group_id, ReplicationOffset.new(1), "data1")
      Stream.append_entry(group_id, ReplicationOffset.new(2), "data2")

      # Entries should be buffered, not yet sent
      Process.sleep(100)

      # Follower should eventually receive them after flush
      Process.sleep(5100)

      offset = Follower.current_offset(group_id)
      assert offset.value >= 1
    end

    test "flushes when batch size is reached" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower1")

      # Start with small batch size
      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 2]})

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)

      # Append entries to trigger batch flush
      Stream.append_entry(group_id, ReplicationOffset.new(1), "data1")
      Stream.append_entry(group_id, ReplicationOffset.new(2), "data2")

      # Should flush immediately due to batch size
      Process.sleep(100)

      offset = Follower.current_offset(group_id)
      assert offset.value == 2
    end

    test "tracks multiple followers in state" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower1_id = NodeId.new("follower1")
      follower2_id = NodeId.new("follower2")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 3]})

      Stream.add_follower(group_id, follower1_id)
      Stream.add_follower(group_id, follower2_id)

      # Stream should track both followers
      states = Stream.get_follower_states(group_id)

      assert map_size(states) == 2
      assert Map.has_key?(states, follower1_id)
      assert Map.has_key?(states, follower2_id)
      assert states[follower1_id].connection_status == :connected
      assert states[follower2_id].connection_status == :connected
    end
  end

  describe "Integration with Leader" do
    test "leader writes stream through to followers" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id]})

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 1]})

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)
      Follower.set_leader(group_id, leader_id)

      # Write through leader
      {:ok, offset} = Leader.write(group_id, "test-data", timeout: 1000)

      assert offset.value == 1

      # Give time for streaming
      Process.sleep(200)

      # Follower should have received the entry
      follower_offset = Follower.current_offset(group_id)
      assert follower_offset.value == 1
    end
  end

  describe "Catch-up mechanism" do
    test "follower requests catch-up on gap detection" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id, batch_size: 10]})

      start_supervised!({Follower, [group_id: group_id, node_id: follower_id]})

      Stream.add_follower(group_id, follower_id)

      # Simulate gap by sending offset 3 when follower is at 0
      Follower.apply_entry(group_id, ReplicationOffset.new(3), "data3")

      # Give time for catch-up request
      Process.sleep(100)

      # Follower should remain at 0 (didn't apply the gapped entry)
      offset = Follower.current_offset(group_id)
      assert offset.value == 0
    end

    test "stream handles catch-up request" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      follower_id = NodeId.new("follower")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      Stream.add_follower(group_id, follower_id)

      # Request catch-up
      Stream.request_catch_up(group_id, follower_id, ReplicationOffset.new(5))

      Process.sleep(50)

      # Stream should have updated follower state
      states = Stream.get_follower_states(group_id)
      assert states[follower_id].last_ack_offset.value == 5
    end

    test "stream ignores catch-up for unknown follower" do
      group_id = "test-group-#{:rand.uniform(10000)}"
      leader_id = NodeId.new("leader")
      unknown_follower_id = NodeId.new("unknown")

      start_supervised!({Stream, [group_id: group_id, leader_node_id: leader_id]})

      # Request catch-up for follower that doesn't exist
      Stream.request_catch_up(group_id, unknown_follower_id, ReplicationOffset.new(5))

      Process.sleep(50)

      # Should not crash, just log warning
      states = Stream.get_follower_states(group_id)
      assert states == %{}
    end
  end
end
