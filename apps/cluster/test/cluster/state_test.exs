defmodule Cluster.StateTest do
  use ExUnit.Case, async: true

  alias Cluster.State
  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeJoined, NodeLeft, NodeDetectedDown}
  alias CoreDomain.Types.NodeId

  describe "new/1" do
    test "creates a new cluster with local node ID" do
      node_id = NodeId.new("local_node")
      cluster = State.new(node_id)

      assert cluster.local_node_id == node_id
      assert cluster.nodes == %{}
      assert cluster.events == []
    end
  end

  describe "add_node/2" do
    test "adds a node to the cluster" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, updated_cluster} = State.add_node(cluster, node)

      assert map_size(updated_cluster.nodes) == 1
      assert Map.has_key?(updated_cluster.nodes, node_id)
    end

    test "emits NodeJoined event" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, updated_cluster} = State.add_node(cluster, node)

      assert [%NodeJoined{node_id: ^node_id}] = updated_cluster.events
    end

    test "returns error when adding duplicate node" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, updated_cluster} = State.add_node(cluster, node)
      result = State.add_node(updated_cluster, node)

      assert {:error, :node_already_exists} = result
    end
  end

  describe "remove_node/3" do
    test "removes a node from the cluster" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_node} = State.add_node(cluster, node)
      {_events, cluster_with_node} = State.take_events(cluster_with_node)

      {:ok, updated_cluster} = State.remove_node(cluster_with_node, node_id)

      assert map_size(updated_cluster.nodes) == 0
      refute Map.has_key?(updated_cluster.nodes, node_id)
    end

    test "emits NodeLeft event" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_node} = State.add_node(cluster, node)
      {_events, cluster_with_node} = State.take_events(cluster_with_node)

      {:ok, updated_cluster} = State.remove_node(cluster_with_node, node_id, :graceful)

      assert [%NodeLeft{node_id: ^node_id, reason: :graceful}] = updated_cluster.events
    end

    test "returns error when removing non-existent node" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)
      node_id = NodeId.new("node1")

      result = State.remove_node(cluster, node_id)

      assert {:error, :node_not_found} = result
    end
  end

  describe "mark_node_down/3" do
    test "marks a node as down" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_node} = State.add_node(cluster, node)
      {_events, cluster_with_node} = State.take_events(cluster_with_node)

      {:ok, updated_cluster} = State.mark_node_down(cluster_with_node, node_id)

      {:ok, updated_node} = State.get_node(updated_cluster, node_id)
      assert Node.down?(updated_node)
    end

    test "emits NodeDetectedDown event" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_node} = State.add_node(cluster, node)
      {_events, cluster_with_node} = State.take_events(cluster_with_node)

      {:ok, updated_cluster} =
        State.mark_node_down(cluster_with_node, node_id, :heartbeat_failure)

      assert [%NodeDetectedDown{node_id: ^node_id, detection_method: :heartbeat_failure}] =
               updated_cluster.events
    end
  end

  describe "mark_node_suspect/2" do
    test "marks a node as suspect" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_node} = State.add_node(cluster, node)
      {:ok, updated_cluster} = State.mark_node_suspect(cluster_with_node, node_id)

      {:ok, updated_node} = State.get_node(updated_cluster, node_id)
      assert Node.suspect?(updated_node)
    end
  end

  describe "all_nodes/1" do
    test "returns all nodes in the cluster" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node1 = Node.new(NodeId.new("node1"), "localhost", 4000)
      node2 = Node.new(NodeId.new("node2"), "localhost", 4001)

      {:ok, cluster} = State.add_node(cluster, node1)
      {:ok, cluster} = State.add_node(cluster, node2)

      nodes = State.all_nodes(cluster)

      assert length(nodes) == 2
    end
  end

  describe "nodes_with_status/2" do
    test "returns only nodes with specified status" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node1 = Node.new(NodeId.new("node1"), "localhost", 4000)
      node2 = Node.new(NodeId.new("node2"), "localhost", 4001)

      {:ok, cluster} = State.add_node(cluster, node1)
      {:ok, cluster} = State.add_node(cluster, node2)
      {:ok, cluster} = State.mark_node_down(cluster, node2.id)

      up_nodes = State.nodes_with_status(cluster, :up)
      down_nodes = State.nodes_with_status(cluster, :down)

      assert length(up_nodes) == 1
      assert length(down_nodes) == 1
    end
  end

  describe "take_events/1" do
    test "returns events and clears event list" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)

      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      {:ok, cluster_with_events} = State.add_node(cluster, node)

      {events, cluster_without_events} = State.take_events(cluster_with_events)

      assert length(events) == 1
      assert [%NodeJoined{}] = events
      assert cluster_without_events.events == []
    end
  end
end
