defmodule Cluster.MembershipTest do
  use ExUnit.Case, async: false

  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeJoined, NodeLeft}
  alias Cluster.Membership
  alias CoreDomain.Types.NodeId

  setup do
    # Start the Membership server for each test
    start_supervised!({Membership, [node_id: "test_node"]})
    :ok
  end

  describe "join_node/1" do
    test "successfully joins a node to the cluster" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      assert :ok = Membership.join_node(node)

      nodes = Membership.all_nodes()
      assert length(nodes) == 1
      assert hd(nodes).id == node_id
    end

    test "returns error when joining duplicate node" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      assert :ok = Membership.join_node(node)
      assert {:error, :node_already_exists} = Membership.join_node(node)
    end

    test "broadcasts NodeJoined event to subscribers" do
      Membership.subscribe()

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)

      assert_receive {:cluster_event, %NodeJoined{node_id: ^node_id}}, 1000
    end
  end

  describe "leave_node/2" do
    test "successfully removes a node from the cluster" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)
      assert :ok = Membership.leave_node(node_id)

      nodes = Membership.all_nodes()
      assert nodes == []
    end

    test "returns error when removing non-existent node" do
      node_id = NodeId.new("nonexistent")

      assert {:error, :node_not_found} = Membership.leave_node(node_id)
    end

    test "broadcasts NodeLeft event to subscribers" do
      Membership.subscribe()

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)
      # Clear the join event
      assert_receive {:cluster_event, %NodeJoined{}}, 1000

      Membership.leave_node(node_id, :graceful)

      assert_receive {:cluster_event, %NodeLeft{node_id: ^node_id, reason: :graceful}}, 1000
    end
  end

  describe "get_node/1" do
    test "returns node if it exists" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)

      assert {:ok, retrieved_node} = Membership.get_node(node_id)
      assert retrieved_node.id == node_id
      assert retrieved_node.host == "localhost"
      assert retrieved_node.port == 4000
    end

    test "returns error if node does not exist" do
      node_id = NodeId.new("nonexistent")

      assert {:error, :not_found} = Membership.get_node(node_id)
    end
  end

  describe "all_nodes/0" do
    test "returns empty list when no nodes" do
      assert [] = Membership.all_nodes()
    end

    test "returns all nodes in the cluster" do
      node1 = Node.new(NodeId.new("node1"), "localhost", 4000)
      node2 = Node.new(NodeId.new("node2"), "localhost", 4001)

      Membership.join_node(node1)
      Membership.join_node(node2)

      nodes = Membership.all_nodes()
      assert length(nodes) == 2
    end
  end

  describe "local_node_id/0" do
    test "returns the local node ID" do
      local_id = Membership.local_node_id()

      assert %NodeId{value: "test_node"} = local_id
    end
  end

  describe "subscribe/unsubscribe" do
    test "subscribe adds process to subscribers" do
      assert :ok = Membership.subscribe()

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)

      assert_receive {:cluster_event, %NodeJoined{}}, 1000
    end

    test "unsubscribe removes process from subscribers" do
      Membership.subscribe()
      assert :ok = Membership.unsubscribe()

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      Membership.join_node(node)

      refute_receive {:cluster_event, %NodeJoined{}}, 100
    end

    test "subscriber is removed when process dies" do
      subscriber_pid =
        spawn(fn ->
          Membership.subscribe()

          receive do
            :stop -> :ok
          end
        end)

      # Wait for subscription to be processed
      Process.sleep(10)

      # Kill the subscriber
      Process.exit(subscriber_pid, :kill)
      Process.sleep(10)

      # Join a node - subscriber should not receive event
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      Membership.join_node(node)

      # No error should occur from trying to send to dead process
      assert :ok
    end
  end

  describe "integration: multiple nodes" do
    test "manages multiple nodes with different states" do
      node1 = Node.new(NodeId.new("node1"), "localhost", 4000)
      node2 = Node.new(NodeId.new("node2"), "localhost", 4001)
      node3 = Node.new(NodeId.new("node3"), "localhost", 4002)

      Membership.join_node(node1)
      Membership.join_node(node2)
      Membership.join_node(node3)

      nodes = Membership.all_nodes()
      assert length(nodes) == 3

      Membership.leave_node(node2.id)

      nodes = Membership.all_nodes()
      assert length(nodes) == 2
      assert Enum.all?(nodes, fn n -> n.id != node2.id end)
    end
  end

  describe "Erlang distribution recovery" do
    test "nodeup marks a known down member back up and emits NodeRecovered" do
      node_id = NodeId.new("n1")
      :ok = Membership.join_node(Node.new(node_id, "localhost", 4000))

      Membership.subscribe()

      # Simulate the distribution connection dropping, then coming back.
      send(Membership, {:nodedown, :n1@localhost, %{}})
      assert_receive {:cluster_event, %Cluster.Events.NodeDetectedDown{node_id: ^node_id}}
      {:ok, down} = Membership.get_node(node_id)
      assert down.status == :down

      send(Membership, {:nodeup, :n1@localhost, %{}})
      assert_receive {:cluster_event, %Cluster.Events.NodeRecovered{node_id: ^node_id}}
      {:ok, recovered} = Membership.get_node(node_id)
      assert recovered.status == :up
    end

    test "nodeup for an already-up member emits no event" do
      node_id = NodeId.new("n2")
      :ok = Membership.join_node(Node.new(node_id, "localhost", 4001))

      Membership.subscribe()
      send(Membership, {:nodeup, :n2@localhost, %{}})

      refute_receive {:cluster_event, %Cluster.Events.NodeRecovered{}}, 100
      {:ok, node} = Membership.get_node(node_id)
      assert node.status == :up
    end

    test "nodeup for an unknown Erlang node is ignored" do
      Membership.subscribe()
      send(Membership, {:nodeup, :ghost@nowhere, %{}})

      refute_receive {:cluster_event, _}, 100
    end

    test "apply_remote_event/1 applies a peer's membership changes idempotently" do
      alias Cluster.Events.{NodeDetectedDown, NodeJoined, NodeLeft, NodeRecovered}

      node_id = NodeId.new("remote-1")
      node = Node.new(node_id, "10.0.0.9", 4000)

      # Join from a peer.
      Membership.apply_remote_event(NodeJoined.new(node))
      assert {:ok, joined} = Membership.get_node(node_id)
      assert joined.host == "10.0.0.9"

      # Duplicate join is ignored (idempotent, no crash).
      Membership.apply_remote_event(NodeJoined.new(node))
      assert length(Membership.all_nodes()) == 1

      # Down / recovered transitions.
      Membership.apply_remote_event(NodeDetectedDown.new(node_id, :network_partition))
      assert {:ok, down} = Membership.get_node(node_id)
      assert down.status == :down

      Membership.apply_remote_event(NodeRecovered.new(node_id))
      assert {:ok, up} = Membership.get_node(node_id)
      assert up.status == :up

      # Leave removes it; a repeat and unknown events are ignored.
      Membership.apply_remote_event(NodeLeft.new(node_id, :graceful))
      assert {:error, :not_found} = Membership.get_node(node_id)

      Membership.apply_remote_event(NodeLeft.new(node_id, :graceful))
      Membership.apply_remote_event(%{type: :bogus})
      assert Membership.all_nodes() == []
    end

    test "merge_membership/1 adds unknown peer nodes idempotently (anti-entropy)" do
      # A node already known locally.
      local_known = Node.new(NodeId.new("known-1"), "h", 4001)
      :ok = Membership.join_node(local_known)

      # A peer's view including the known node plus two we have never seen.
      peer_nodes = [
        local_known,
        Node.new(NodeId.new("peer-a"), "10.0.0.1", 4000),
        Node.new(NodeId.new("peer-b"), "10.0.0.2", 4000)
      ]

      Membership.merge_membership(peer_nodes)

      ids = Membership.all_nodes() |> Enum.map(& &1.id.value) |> Enum.sort()
      assert ids == ["known-1", "peer-a", "peer-b"]
      assert {:ok, a} = Membership.get_node(NodeId.new("peer-a"))
      assert a.host == "10.0.0.1"

      # Merging again changes nothing.
      Membership.merge_membership(peer_nodes)
      assert length(Membership.all_nodes()) == 3
    end

    test "repeated nodedown for an already-down node does not re-broadcast" do
      node_id = NodeId.new("n1")
      :ok = Membership.join_node(Node.new(node_id, "localhost", 4000))

      Membership.subscribe()

      send(Membership, {:nodedown, :n1@localhost, %{}})
      assert_receive {:cluster_event, %Cluster.Events.NodeDetectedDown{node_id: ^node_id}}

      # A second nodedown while already down must be a no-op — no spurious event.
      send(Membership, {:nodedown, :n1@localhost, %{}})
      refute_receive {:cluster_event, %Cluster.Events.NodeDetectedDown{}}, 100
    end
  end
end
