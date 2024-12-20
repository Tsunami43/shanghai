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

  describe "has_address?/2" do
    test "detects whether an address is in use" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))

      assert State.has_address?(cluster, "hostA:4001")
      refute State.has_address?(cluster, "hostZ:9999")
    end
  end

  describe "addresses_with_status/2" do
    test "returns sorted addresses for a status" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostB", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      assert State.addresses_with_status(cluster, :up) == ["hostB:4001"]
      assert State.addresses_with_status(cluster, :down) == ["hostA:4002"]
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

  describe "node_hosts/1" do
    test "returns distinct sorted hosts" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostB", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n3"), "hostA", 4003))

      assert State.node_hosts(cluster) == ["hostA", "hostB"]
      assert State.node_hosts(State.new(NodeId.new("solo"))) == []
    end
  end

  describe "nodes_on_host/2" do
    test "returns nodes on a host sorted by id" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n3"), "hostB", 4003))

      on_a = State.nodes_on_host(cluster, "hostA")
      assert Enum.map(on_a, & &1.id.value) == ["n1", "n2"]
      assert State.nodes_on_host(cluster, "hostC") == []
    end
  end

  describe "duplicate_addresses?/1" do
    test "detects two nodes sharing an address" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      refute State.duplicate_addresses?(cluster)

      {:ok, dup} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4001))
      assert State.duplicate_addresses?(dup)
    end
  end

  describe "count_on_host/2" do
    test "counts nodes on a host" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n3"), "hostB", 4003))

      assert State.count_on_host(cluster, "hostA") == 2
      assert State.count_on_host(cluster, "hostC") == 0
    end
  end

  describe "hosts_summary/1" do
    test "counts nodes per host" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n3"), "hostB", 4003))

      assert State.hosts_summary(cluster) == %{"hostA" => 2, "hostB" => 1}
      assert State.hosts_summary(State.new(NodeId.new("solo"))) == %{}
    end
  end

  describe "single_node?/1" do
    test "detects a solo deployment" do
      cluster = State.new(NodeId.new("local"))
      refute State.single_node?(cluster)

      {:ok, one} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      assert State.single_node?(one)

      {:ok, two} = State.add_node(one, Node.new(NodeId.new("n2"), "h", 4002))
      refute State.single_node?(two)
    end
  end

  describe "node_ids_with_status/2" do
    test "returns sorted ids for a status" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      assert Enum.map(State.node_ids_with_status(cluster, :up), & &1.value) == ["n1"]
      assert Enum.map(State.node_ids_with_status(cluster, :down), & &1.value) == ["n2"]
    end
  end

  describe "multi_host?/1" do
    test "detects nodes spread across hosts" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "hostA", 4002))
      refute State.multi_host?(cluster)

      {:ok, spread} = State.add_node(cluster, Node.new(NodeId.new("n3"), "hostB", 4003))
      assert State.multi_host?(spread)
    end
  end

  describe "available_node_ids/1" do
    test "returns sorted ids of up nodes" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      assert Enum.map(State.available_node_ids(cluster), & &1.value) == ["n1"]
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

  describe "available_nodes/1" do
    test "returns up nodes sorted by id" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      assert Enum.map(State.available_nodes(cluster), & &1.id.value) == ["n1"]
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

  describe "stalest_node/1" do
    test "returns nil for an empty cluster" do
      assert State.stalest_node(State.new(NodeId.new("local"))) == nil
    end

    test "returns the node with the oldest heartbeat" do
      cluster = State.new(NodeId.new("local"))

      fresh = Node.new(NodeId.new("fresh"), "h", 4001)

      old = %{
        Node.new(NodeId.new("old"), "h", 4002)
        | last_seen_at: DateTime.add(DateTime.utc_now(), -100, :second)
      }

      {:ok, cluster} = State.add_node(cluster, fresh)
      {:ok, cluster} = State.add_node(cluster, old)

      assert State.stalest_node(cluster).id.value == "old"
    end

    test "ranks a never-seen node as stalest" do
      cluster = State.new(NodeId.new("local"))
      seen = Node.new(NodeId.new("seen"), "h", 4001)
      never = %{Node.new(NodeId.new("never"), "h", 4002) | last_seen_at: nil}

      {:ok, cluster} = State.add_node(cluster, seen)
      {:ok, cluster} = State.add_node(cluster, never)

      assert State.stalest_node(cluster).id.value == "never"
    end
  end

  describe "freshest_node/1" do
    test "returns nil for an empty cluster" do
      assert State.freshest_node(State.new(NodeId.new("local"))) == nil
    end

    test "returns the node with the most recent heartbeat" do
      cluster = State.new(NodeId.new("local"))

      old = %{
        Node.new(NodeId.new("old"), "h", 4001)
        | last_seen_at: DateTime.add(DateTime.utc_now(), -100, :second)
      }

      fresh = Node.new(NodeId.new("fresh"), "h", 4002)

      {:ok, cluster} = State.add_node(cluster, old)
      {:ok, cluster} = State.add_node(cluster, fresh)

      assert State.freshest_node(cluster).id.value == "fresh"
    end
  end

  describe "nodes_with_statuses/2" do
    test "returns nodes matching any of the statuses" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n3"), "h", 4003))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))
      {:ok, cluster} = State.mark_node_suspect(cluster, NodeId.new("n3"))

      matched = State.nodes_with_statuses(cluster, [:down, :suspect])
      assert length(matched) == 2
      assert Enum.all?(matched, &(&1.status in [:down, :suspect]))
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

  describe "local?/2" do
    test "identifies the local node id" do
      local = NodeId.new("local")
      cluster = State.new(local)

      assert State.local?(cluster, local)
      refute State.local?(cluster, NodeId.new("other"))
    end
  end

  describe "peer_ids/1" do
    test "returns members except the local node, sorted" do
      local = NodeId.new("local")
      cluster = State.new(local)
      {:ok, cluster} = State.add_node(cluster, Node.new(local, "h", 4000))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))

      assert Enum.map(State.peer_ids(cluster), & &1.value) == ["n1", "n2"]
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

  describe "status_of/2" do
    test "returns a node status or nil" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n1"))

      assert State.status_of(cluster, NodeId.new("n1")) == :down
      assert State.status_of(cluster, NodeId.new("missing")) == nil
    end
  end

  describe "metadata_of/2" do
    test "returns a node metadata or nil" do
      cluster = State.new(NodeId.new("local"))

      {:ok, cluster} =
        State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001, %{role: "leader"}))

      assert State.metadata_of(cluster, NodeId.new("n1")) == %{role: "leader"}
      assert State.metadata_of(cluster, NodeId.new("missing")) == nil
    end
  end

  describe "address_of/2" do
    test "returns a node address or nil" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "hostA", 4001))

      assert State.address_of(cluster, NodeId.new("n1")) == "hostA:4001"
      assert State.address_of(cluster, NodeId.new("missing")) == nil
    end
  end

  describe "pending_event_count/1 and pending_events?/1" do
    test "track uncommitted events" do
      cluster = State.new(NodeId.new("local"))
      refute State.pending_events?(cluster)
      assert State.pending_event_count(cluster) == 0

      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      assert State.pending_events?(cluster)
      assert State.pending_event_count(cluster) == 1

      {_events, cleared} = State.take_events(cluster)
      refute State.pending_events?(cleared)
    end
  end

  describe "peek_events/1" do
    test "returns pending events without clearing them" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))

      events = State.peek_events(cluster)
      assert length(events) == 1
      # Still pending after a peek.
      assert State.pending_event_count(cluster) == 1
    end
  end

  describe "clear_events/1" do
    test "drops pending events" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      assert State.pending_event_count(cluster) == 1

      cleared = State.clear_events(cluster)
      assert State.pending_event_count(cleared) == 0
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

  describe "majority?/2" do
    test "checks whether a count is a strict majority" do
      cluster =
        Enum.reduce(1..5, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "h", 4000 + i))
          next
        end)

      refute State.majority?(cluster, 2)
      assert State.majority?(cluster, 3)
      assert State.majority?(cluster, 5)
      refute State.majority?(State.new(NodeId.new("solo")), 1)
    end
  end

  describe "describe/1" do
    test "renders a compact cluster description" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n2"))

      assert State.describe(cluster) == "2 nodes (1/0/1)"
    end
  end

  describe "status_ratio/2" do
    test "returns the fraction of nodes with a status" do
      cluster =
        Enum.reduce(1..4, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "h", 4000 + i))
          next
        end)

      {:ok, cluster} = State.mark_node_down(cluster, NodeId.new("n1"))

      assert State.status_ratio(cluster, :up) == 0.75
      assert State.status_ratio(cluster, :down) == 0.25
      assert State.status_ratio(State.new(NodeId.new("solo")), :up) == 0.0
    end
  end

  describe "quorum_shortfall/1" do
    test "reports how many more up nodes are needed for quorum" do
      cluster =
        Enum.reduce(1..3, State.new(NodeId.new("local")), fn i, acc ->
          {:ok, next} = State.add_node(acc, Node.new(NodeId.new("n#{i}"), "h", 4000 + i))
          next
        end)

      # 3 up, quorum 2 -> already available
      assert State.quorum_shortfall(cluster) == 0

      {:ok, two_down} = State.mark_node_down(cluster, NodeId.new("n1"))
      {:ok, two_down} = State.mark_node_down(two_down, NodeId.new("n2"))
      # 1 up, quorum 2 -> need 1 more
      assert State.quorum_shortfall(two_down) == 1
    end
  end

  describe "all_up?/1" do
    test "is true only when every node is up" do
      refute State.all_up?(State.new(NodeId.new("local")))

      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n2"), "h", 4002))
      assert State.all_up?(cluster)

      {:ok, degraded} = State.mark_node_down(cluster, NodeId.new("n2"))
      refute State.all_up?(degraded)
    end
  end

  describe "degraded?/1" do
    test "is true when any node is down or suspect" do
      cluster = State.new(NodeId.new("local"))
      {:ok, cluster} = State.add_node(cluster, Node.new(NodeId.new("n1"), "h", 4001))
      refute State.degraded?(cluster)

      {:ok, down} = State.mark_node_down(cluster, NodeId.new("n1"))
      assert State.degraded?(down)
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
