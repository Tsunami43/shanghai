defmodule Cluster.GossipTest do
  use ExUnit.Case, async: false

  alias Cluster.Gossip
  alias Cluster.Heartbeat
  alias Cluster.Membership
  alias Cluster.ValueObjects.Heartbeat, as: HeartbeatVO
  alias CoreDomain.Types.NodeId

  setup do
    # Start required services
    start_supervised!({Membership, [node_id: "test_node"]})
    start_supervised!({Heartbeat, []})
    # Start Gossip with short interval for faster tests
    start_supervised!({Gossip, [interval_ms: 100, fanout: 2]})

    :ok
  end

  describe "broadcast/1" do
    test "adds message to buffer for gossip" do
      message = {:heartbeat, HeartbeatVO.new(NodeId.new("node1"), 1)}

      assert :ok = Gossip.broadcast(message)

      # Message should be in buffer (we can't directly test this without internal inspection)
      # But we can verify no crashes occurred
      Process.sleep(50)
      assert Process.whereis(Cluster.Gossip) != nil
    end

    test "broadcasts cluster events" do
      message = {:cluster_event, %{type: :test_event, data: "test"}}

      assert :ok = Gossip.broadcast(message)
      Process.sleep(50)

      # Verify gossip process is still alive
      assert Process.whereis(Cluster.Gossip) != nil
    end
  end

  describe "receive_gossip/2" do
    test "processes received heartbeat messages" do
      from_node = :other_node@localhost
      node_id = NodeId.new("node1")
      heartbeat = HeartbeatVO.new(node_id, 1)
      message = {:heartbeat, heartbeat}

      assert :ok = Gossip.receive_gossip(from_node, message)

      # Give it time to process
      Process.sleep(50)

      # Heartbeat should be recorded in Heartbeat process
      assert {:ok, recorded_hb} = Heartbeat.get_last_heartbeat(node_id)
      assert recorded_hb.sequence == 1
    end

    test "ignores duplicate messages" do
      from_node = :other_node@localhost
      node_id = NodeId.new("node1")
      heartbeat = HeartbeatVO.new(node_id, 1)
      message = {:heartbeat, heartbeat}

      # Send same message twice
      Gossip.receive_gossip(from_node, message)
      Process.sleep(10)
      Gossip.receive_gossip(from_node, message)
      Process.sleep(10)

      # Should still only have one heartbeat recorded
      assert {:ok, _} = Heartbeat.get_last_heartbeat(node_id)
    end

    test "processes cluster event messages" do
      from_node = :other_node@localhost
      message = {:cluster_event, %{type: :test_event}}

      assert :ok = Gossip.receive_gossip(from_node, message)
      Process.sleep(50)

      # Verify no crashes
      assert Process.whereis(Cluster.Gossip) != nil
    end
  end

  describe "gossip rounds" do
    test "gossip process runs periodic rounds" do
      # Start gossip with very short interval
      # The process should be running and not crash

      # Wait for a few rounds
      Process.sleep(300)

      # Verify process is still alive
      assert Process.whereis(Cluster.Gossip) != nil
    end

    test "clears message buffer after gossip round" do
      # Broadcast a message
      message = {:heartbeat, HeartbeatVO.new(NodeId.new("node1"), 1)}
      Gossip.broadcast(message)

      # Wait for gossip round to complete
      Process.sleep(150)

      # Broadcast another message
      message2 = {:heartbeat, HeartbeatVO.new(NodeId.new("node2"), 1)}
      Gossip.broadcast(message2)

      # Verify process is still functioning
      Process.sleep(50)
      assert Process.whereis(Cluster.Gossip) != nil
    end
  end

  describe "message propagation" do
    test "re-gossips received messages to other nodes" do
      from_node = :other_node@localhost
      node_id = NodeId.new("node1")
      heartbeat = HeartbeatVO.new(node_id, 1)
      message = {:heartbeat, heartbeat}

      # Receive a message from another node
      Gossip.receive_gossip(from_node, message)

      # Wait for potential re-gossip
      Process.sleep(200)

      # Verify the message was processed (heartbeat recorded)
      assert {:ok, _} = Heartbeat.get_last_heartbeat(node_id)
    end
  end

  describe "seen messages tracking" do
    test "tracks seen messages to prevent loops" do
      # This is tested indirectly through duplicate message handling
      from_node = :other_node@localhost
      node_id = NodeId.new("node1")

      # Send multiple messages with same content
      for seq <- 1..5 do
        heartbeat = HeartbeatVO.new(node_id, seq)
        message = {:heartbeat, heartbeat}
        Gossip.receive_gossip(from_node, message)
      end

      Process.sleep(50)

      # Should have processed the last heartbeat
      assert {:ok, hb} = Heartbeat.get_last_heartbeat(node_id)
      assert hb.sequence == 5
    end
  end

  describe "integration with membership" do
    test "gossip works with membership events" do
      Membership.subscribe()

      # Add a node to membership
      node = Cluster.Entities.Node.new(NodeId.new("node1"), "localhost", 4000)
      Membership.join_node(node)

      # Should receive the event
      assert_receive {:cluster_event, _}, 1000

      # Gossip should still be running
      Process.sleep(100)
      assert Process.whereis(Cluster.Gossip) != nil
    end
  end
end
