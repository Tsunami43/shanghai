defmodule Cluster.StateTest do
  use ExUnit.Case, async: true

  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeDetectedDown, NodeJoined, NodeLeft}
  alias Cluster.State
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

  describe "get_node_by_address/2" do
    test "finds a node by its host:port address" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostB", 4002))

      assert {:ok, node} = State.get_node_by_address(cluster, "hostB:4002")
      assert node.id.value == "n2"
      assert {:error, :not_found} = State.get_node_by_address(cluster, "nope:1")
    end
  end

  describe "node_addresses/1" do
    test "returns sorted host:port addresses" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("nb"), "h2", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("na"), "h1", 4002))

      assert State.node_addresses(cluster) == ["h1:4002", "h2:4001"]
    end
  end

  describe "node_ids/1" do
    test "returns sorted node ids" do
      cluster =
        State.new(NodeId.new("local"))

      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("nb"), "localhost", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("na"), "localhost", 4002))

      assert State.node_ids(cluster) == [NodeId.new("na"), NodeId.new("nb")]
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

  describe "nodes_by_status/1" do
    test "groups nodes by status with sorted lists" do
      cluster = State.new(NodeId.new("local"))

      n1 = Node.new(NodeId.new("n1"), "localhost", 4001)
      n2 = Node.new(NodeId.new("n2"), "localhost", 4002)
      n3 = Node.new(NodeId.new("n3"), "localhost", 4003)

      {:ok, cluster} = State.add_node(cluster, n2)
      {:ok, cluster} = State.add_node(cluster, n1)
      {:ok, cluster} = State.add_node(cluster, n3)
      {:ok, cluster} = State.mark_node_down(cluster, n3.id)

      grouped = State.nodes_by_status(cluster)

      assert Enum.map(grouped.up, & &1.id.value) == ["n1", "n2"]
      assert Enum.map(grouped.down, & &1.id.value) == ["n3"]
      assert grouped.suspect == []
    end
  end

  describe "topology/1" do
    test "returns a serializable snapshot of the cluster" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      topo = State.topology(cluster)

      assert topo.local_node_id == "local"
      assert topo.node_count == 2
      assert topo.status_summary == %{up: 1, suspect: 0, down: 1}
      assert Enum.map(topo.nodes, & &1.id) == ["n1", "n2"]
      assert Enum.all?(topo.nodes, &is_map/1)
    end

    test "handles an empty cluster" do
      topo = State.topology(State.new(NodeId.new("solo")))
      assert topo.node_count == 0
      assert topo.nodes == []
    end
  end

  describe "local_node/1" do
    test "returns nil until the local node joins, then the entity" do
      local_id = NodeId.new("local")
      cluster = State.new(local_id)
      assert State.local_node(cluster) == nil

      {:ok, cluster} = State.add_node(cluster, Node.new(local_id, "localhost", 4000))
      assert %Node{id: ^local_id} = State.local_node(cluster)
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

  describe "health_ratio/1" do
    test "is 0.0 for an empty cluster and 1.0 when all up" do
      assert State.health_ratio(State.new(NodeId.new("local"))) == 0.0

      cluster =
        Enum.reduce(1..2, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("h#{i}"), "localhost", 4000 + i))
          next
        end)

      assert State.health_ratio(cluster) == 1.0

      {:ok, one_down} = State.mark_node_down(cluster, NodeId.new("h1"), :timeout)
      assert State.health_ratio(one_down) == 0.5
    end
  end

  describe "empty?/1" do
    test "reflects whether the cluster has nodes" do
      cluster = State.new(NodeId.new("local"))
      assert State.empty?(cluster)
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "localhost", 4001))
      refute State.empty?(cluster)
    end
  end

  describe "status_summary/1" do
    test "counts nodes per status" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "localhost", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "localhost", 4002))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"), :timeout)

      assert State.status_summary(cluster) == %{up: 1, suspect: 0, down: 1}
    end
  end

  describe "quorum_size/1" do
    test "is zero for an empty cluster and the majority otherwise" do
      assert State.quorum_size(State.new(NodeId.new("local"))) == 0

      cluster =
        Enum.reduce(1..3, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "localhost", 4000 + i))
          next
        end)

      assert State.quorum_size(cluster) == 2
    end
  end

  describe "fault_tolerance/1" do
    test "is zero for empty and single-node clusters" do
      assert State.fault_tolerance(State.new(NodeId.new("local"))) == 0

      {:ok, one} =
        State.add_node(
          State.new(NodeId.new("local")),
          Node.new(NodeId.new("n1"), "localhost", 4001)
        )

      assert State.fault_tolerance(one) == 0
    end

    test "is n - quorum_size for larger clusters" do
      cluster =
        Enum.reduce(1..5, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "localhost", 4000 + i))
          next
        end)

      assert State.fault_tolerance(cluster) == 2
    end
  end

  describe "quorum_available?/1" do
    test "is false for an empty cluster" do
      refute State.quorum_available?(State.new(NodeId.new("local")))
    end

    test "is true only when a strict majority is up" do
      cluster =
        Enum.reduce(1..3, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "localhost", 4000 + i))
          next
        end)

      assert State.quorum_available?(cluster)

      {:ok, one_down} = State.mark_node_down(cluster, NodeId.new("n1"), :timeout)
      assert State.quorum_available?(one_down)

      {:ok, two_down} = State.mark_node_down(one_down, NodeId.new("n2"), :timeout)
      refute State.quorum_available?(two_down)
    end
  end
end
