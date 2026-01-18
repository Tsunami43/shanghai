defmodule Cluster.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Cluster.Entities.Node
  alias Cluster.Events.NodeDetectedDown
  alias Cluster.Heartbeat
  alias Cluster.Membership
  alias Cluster.ValueObjects.Heartbeat, as: HeartbeatVO
  alias CoreDomain.Types.NodeId

  setup do
    # Start Membership first (Heartbeat depends on it)
    start_supervised!({Membership, [node_id: "test_node"]})
    # Start Heartbeat with short intervals for faster tests
    start_supervised!(
      {Heartbeat,
       [
         interval_ms: 100,
         timeout_ms: 500,
         suspect_timeout_ms: 300
       ]}
    )

    :ok
  end

  describe "record_heartbeat/1" do
    test "records a heartbeat from a node" do
      node_id = NodeId.new("node1")
      heartbeat = HeartbeatVO.new(node_id, 1)

      assert :ok = Heartbeat.record_heartbeat(heartbeat)

      # Give it time to process
      Process.sleep(10)

      assert {:ok, recorded_hb} = Heartbeat.get_last_heartbeat(node_id)
      assert recorded_hb.node_id == node_id
      assert recorded_hb.sequence == 1
    end

    test "updates heartbeat with newer sequence" do
      node_id = NodeId.new("node1")
      hb1 = HeartbeatVO.new(node_id, 1)
      hb2 = HeartbeatVO.new(node_id, 2)

      Heartbeat.record_heartbeat(hb1)
      Process.sleep(10)
      Heartbeat.record_heartbeat(hb2)
      Process.sleep(10)

      assert {:ok, recorded_hb} = Heartbeat.get_last_heartbeat(node_id)
      assert recorded_hb.sequence == 2
    end
  end

  describe "get_last_heartbeat/1" do
    test "returns error when no heartbeat recorded" do
      node_id = NodeId.new("nonexistent")

      assert {:error, :not_found} = Heartbeat.get_last_heartbeat(node_id)
    end

    test "returns last heartbeat for node" do
      node_id = NodeId.new("node1")
      heartbeat = HeartbeatVO.new(node_id, 42)

      Heartbeat.record_heartbeat(heartbeat)
      Process.sleep(10)

      assert {:ok, recorded_hb} = Heartbeat.get_last_heartbeat(node_id)
      assert recorded_hb.sequence == 42
    end
  end

  describe "all_heartbeats/0" do
    test "returns empty map when no heartbeats" do
      heartbeats = Heartbeat.all_heartbeats()
      assert heartbeats == %{}
    end

    test "returns all tracked heartbeats" do
      node1_id = NodeId.new("node1")
      node2_id = NodeId.new("node2")

      hb1 = HeartbeatVO.new(node1_id, 1)
      hb2 = HeartbeatVO.new(node2_id, 1)

      Heartbeat.record_heartbeat(hb1)
      Heartbeat.record_heartbeat(hb2)
      Process.sleep(10)

      heartbeats = Heartbeat.all_heartbeats()
      assert map_size(heartbeats) == 2
      assert Map.has_key?(heartbeats, node1_id)
      assert Map.has_key?(heartbeats, node2_id)
    end
  end

  describe "heartbeat timeout detection" do
    test "marks node as suspect after suspect timeout" do
      Membership.subscribe()

      # Add a node to membership
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      Membership.join_node(node)

      # Clear the join event
      assert_receive {:cluster_event, _}, 1000

      # Record an initial heartbeat
      heartbeat = HeartbeatVO.new(node_id, 1)
      Heartbeat.record_heartbeat(heartbeat)

      # Wait for suspect timeout (300ms) + check interval (100ms)
      Process.sleep(500)

      # Node should be marked as suspect
      {:ok, updated_node} = Membership.get_node(node_id)
      assert Node.suspect?(updated_node)
    end

    test "marks node as down after full timeout" do
      Membership.subscribe()

      # Add a node to membership
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      Membership.join_node(node)

      # Clear the join event
      assert_receive {:cluster_event, _}, 1000

      # Record an initial heartbeat
      heartbeat = HeartbeatVO.new(node_id, 1)
      Heartbeat.record_heartbeat(heartbeat)

      # Wait for full timeout (500ms) + check interval (100ms)
      Process.sleep(700)

      # Node should be marked as down and event should be emitted
      {:ok, updated_node} = Membership.get_node(node_id)
      assert Node.down?(updated_node)

      assert_receive {:cluster_event, %NodeDetectedDown{node_id: ^node_id}}, 1000
    end

    test "resets missed count when heartbeat received" do
      # Add a node to membership
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      Membership.join_node(node)

      # Record initial heartbeat
      heartbeat1 = HeartbeatVO.new(node_id, 1)
      Heartbeat.record_heartbeat(heartbeat1)
      Process.sleep(50)

      # Wait for suspect timeout but not full timeout
      Process.sleep(350)

      # Send fresh heartbeat to reset the timer
      heartbeat2 = HeartbeatVO.new(node_id, 2)
      Heartbeat.record_heartbeat(heartbeat2)

      # Wait for at least two heartbeat check cycles to ensure recovery is processed
      Process.sleep(250)

      # Node should still be up because we reset the timer with the fresh heartbeat
      {:ok, updated_node} = Membership.get_node(node_id)
      assert Node.up?(updated_node)
    end
  end

  describe "heartbeat metrics" do
    test "heartbeat can include custom metrics" do
      node_id = NodeId.new("node1")
      metrics = %{cpu_usage: 0.5, memory_usage: 0.7}
      heartbeat = HeartbeatVO.new(node_id, 1, metrics)

      Heartbeat.record_heartbeat(heartbeat)
      Process.sleep(10)

      {:ok, recorded_hb} = Heartbeat.get_last_heartbeat(node_id)
      assert recorded_hb.metrics == metrics
    end
  end
end
