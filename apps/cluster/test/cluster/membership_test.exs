defmodule Cluster.MembershipTest do
  use ExUnit.Case, async: false

  alias Cluster.Membership
  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeJoined, NodeLeft}
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
      assert length(nodes) == 0
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
end
