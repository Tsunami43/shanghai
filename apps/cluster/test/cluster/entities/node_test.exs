defmodule Cluster.Entities.NodeTest do
  use ExUnit.Case, async: true

  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  describe "new/4" do
    test "creates a new node with default values" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      assert node.id == node_id
      assert node.host == "localhost"
      assert node.port == 4000
      assert node.status == :up
      assert node.metadata == %{}
      assert node.last_seen_at != nil
    end

    test "creates a node with custom metadata" do
      node_id = NodeId.new("node1")
      metadata = %{region: "us-west", datacenter: "dc1"}
      node = Node.new(node_id, "localhost", 4000, metadata)

      assert node.metadata == metadata
    end
  end

  describe "mark_up/1" do
    test "marks a down node as up and refreshes last_seen_at" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      # Pin the down node's timestamp to the past so the refresh is observable
      # regardless of wall-clock resolution (two utc_now/0 calls can otherwise
      # land in the same microsecond).
      old_seen = DateTime.add(DateTime.utc_now(), -60, :second)
      down_node = %{Node.mark_down(node) | last_seen_at: old_seen}

      up_node = Node.mark_up(down_node)

      assert up_node.status == :up
      assert DateTime.compare(up_node.last_seen_at, old_seen) == :gt
    end
  end

  describe "mark_down/1" do
    test "marks an up node as down" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      down_node = Node.mark_down(node)

      assert down_node.status == :down
    end
  end

  describe "mark_suspect/1" do
    test "marks an up node as suspect" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      suspect_node = Node.mark_suspect(node)

      assert suspect_node.status == :suspect
    end
  end

  describe "status predicates" do
    test "up?/1 returns true for up nodes" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      assert Node.up?(node)
    end

    test "down?/1 returns true for down nodes" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      down_node = Node.mark_down(node)

      assert Node.down?(down_node)
    end

    test "suspect?/1 returns true for suspect nodes" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      suspect_node = Node.mark_suspect(node)

      assert Node.suspect?(suspect_node)
    end
  end

  describe "update_metadata/2" do
    test "updates node metadata" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000, %{region: "us-west"})

      updated_node = Node.update_metadata(node, %{datacenter: "dc1"})

      assert updated_node.metadata == %{region: "us-west", datacenter: "dc1"}
    end

    test "overwrites existing keys" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000, %{region: "us-west"})

      updated_node = Node.update_metadata(node, %{region: "us-east"})

      assert updated_node.metadata == %{region: "us-east"}
    end
  end

  describe "touch/1" do
    test "updates last_seen_at timestamp" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      old_timestamp = node.last_seen_at

      Process.sleep(10)
      touched_node = Node.touch(node)

      assert DateTime.compare(touched_node.last_seen_at, old_timestamp) == :gt
    end
  end

  describe "erlang_node_name/1" do
    test "generates correct Erlang node name" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)

      erlang_name = Node.erlang_node_name(node)

      assert erlang_name == :node1@localhost
    end
  end

  describe "address/1" do
    test "formats host and port" do
      node = Node.new(NodeId.new("node1"), "10.0.0.1", 4000)
      assert Node.address(node) == "10.0.0.1:4000"
    end
  end

  describe "unavailable?/1" do
    test "is false when up and true otherwise" do
      node = Node.new(NodeId.new("n"), "localhost", 4000)
      refute Node.unavailable?(node)
      assert Node.unavailable?(Node.mark_down(node))
      assert Node.unavailable?(Node.mark_suspect(node))
    end
  end

  describe "never_seen?/1" do
    test "is true until the node is touched" do
      node = %{Node.new(NodeId.new("n"), "localhost", 4000) | last_seen_at: nil}
      assert Node.never_seen?(node)
      refute Node.never_seen?(Node.touch(node))
    end
  end

  describe "last_seen_age_ms/1" do
    test "is nil when never seen and a non-negative integer after touch" do
      node = %{Node.new(NodeId.new("n"), "localhost", 4000) | last_seen_at: nil}
      assert Node.last_seen_age_ms(node) == nil

      touched = Node.touch(node)
      age = Node.last_seen_age_ms(touched)
      assert is_integer(age) and age >= 0
    end
  end

  describe "last_seen_age_seconds/1" do
    test "is nil when never seen and non-negative after a heartbeat" do
      node = %{Node.new(NodeId.new("n"), "localhost", 4000) | last_seen_at: nil}
      assert Node.last_seen_age_seconds(node) == nil

      old = %{node | last_seen_at: DateTime.add(DateTime.utc_now(), -3, :second)}
      assert Node.last_seen_age_seconds(old) >= 3
    end
  end

  describe "stale?/2" do
    test "a never-seen node is stale" do
      node = %{Node.new(NodeId.new("n"), "localhost", 4000) | last_seen_at: nil}
      assert Node.stale?(node, 1_000)
    end

    test "reflects the last-seen age against the threshold" do
      fresh = Node.touch(Node.new(NodeId.new("n"), "localhost", 4000))
      refute Node.stale?(fresh, 60_000)

      old = %{fresh | last_seen_at: DateTime.add(DateTime.utc_now(), -100, :second)}
      assert Node.stale?(old, 1_000)
    end
  end

  describe "to_map/1" do
    test "produces a serializable plain map" do
      node = Node.new(NodeId.new("n7"), "localhost", 4007, %{role: "leader"})

      map = Node.to_map(node)
      assert map.id == "n7"
      assert map.address == "localhost:4007"
      assert map.host == "localhost"
      assert map.port == 4007
      assert map.status == :up
      assert map.metadata == %{role: "leader"}
      assert %DateTime{} = map.last_seen_at
    end
  end

  describe "from_map/1" do
    test "inverts to_map/1 (round-trip)" do
      node = Node.new(NodeId.new("n7"), "localhost", 4007, %{role: "leader"})
      restored = node |> Node.to_map() |> Node.from_map()

      assert restored.id == node.id
      assert restored.host == node.host
      assert restored.port == node.port
      assert restored.status == node.status
      assert restored.metadata == node.metadata
      assert restored.last_seen_at == node.last_seen_at
    end

    test "applies defaults for absent optional fields" do
      node = Node.from_map(%{id: "n1", host: "h", port: 4000})
      assert node.status == :up
      assert node.metadata == %{}
      assert node.last_seen_at == nil
    end
  end

  describe "same_address?/2" do
    test "compares nodes by host:port" do
      a = Node.new(NodeId.new("a"), "hostA", 4001)
      b = Node.new(NodeId.new("b"), "hostA", 4001)
      c = Node.new(NodeId.new("c"), "hostA", 4002)

      assert Node.same_address?(a, b)
      refute Node.same_address?(a, c)
    end
  end

  describe "same_host?/2" do
    test "compares nodes by host" do
      a = Node.new(NodeId.new("a"), "hostA", 4001)
      b = Node.new(NodeId.new("b"), "hostA", 4002)
      c = Node.new(NodeId.new("c"), "hostB", 4003)

      assert Node.same_host?(a, b)
      refute Node.same_host?(a, c)
    end
  end

  describe "describe/1" do
    test "renders a compact one-line description" do
      node = Node.new(NodeId.new("n1"), "localhost", 4000)
      assert Node.describe(node) == "n1@localhost:4000 (up)"

      down = Node.mark_down(node)
      assert Node.describe(down) == "n1@localhost:4000 (down)"
    end
  end

  describe "current?/1" do
    test "matches the running node's erlang name" do
      [name, host] = :erlang.node() |> Atom.to_string() |> String.split("@", parts: 2)
      node = Node.new(NodeId.new(name), host, 4000)
      assert Node.current?(node)

      refute Node.current?(Node.new(NodeId.new("other"), "elsewhere", 4000))
    end
  end

  describe "with_status/2" do
    test "dispatches to the matching mark_* transition" do
      node = Node.new(NodeId.new("n1"), "h", 4000)

      assert Node.with_status(node, :down).status == :down
      assert Node.with_status(node, :suspect).status == :suspect
      assert Node.with_status(Node.mark_down(node), :up).status == :up
    end
  end

  describe "available?/1" do
    test "is the inverse of unavailable?/1" do
      up = Node.new(NodeId.new("n1"), "h", 4000)
      assert Node.available?(up)
      refute Node.available?(Node.mark_down(up))
      assert Node.available?(up) == not Node.unavailable?(up)
    end
  end

  describe "status_in?/2" do
    test "checks membership in a status set" do
      node = Node.new(NodeId.new("n1"), "h", 4000)

      assert Node.status_in?(node, [:up, :suspect])
      refute Node.status_in?(node, [:down, :suspect])
      assert Node.status_in?(Node.mark_down(node), [:down])
    end
  end

  describe "seen?/1" do
    test "is the inverse of never_seen?/1" do
      node = Node.new(NodeId.new("n1"), "h", 4000)
      assert Node.seen?(node)

      never = %{node | last_seen_at: nil}
      refute Node.seen?(never)
      assert Node.seen?(node) == not Node.never_seen?(node)
    end
  end

  describe "on_port?/2" do
    test "checks the node's port" do
      node = Node.new(NodeId.new("n1"), "h", 4000)
      assert Node.on_port?(node, 4000)
      refute Node.on_port?(node, 4001)
    end
  end

  describe "on_host?/2" do
    test "checks the node's host" do
      node = Node.new(NodeId.new("n1"), "hostA", 4000)
      assert Node.on_host?(node, "hostA")
      refute Node.on_host?(node, "hostB")
    end
  end

  describe "at_address?/2" do
    test "matches the node host:port address" do
      node = Node.new(NodeId.new("n1"), "hostA", 4000)
      assert Node.at_address?(node, "hostA:4000")
      refute Node.at_address?(node, "hostA:4001")
    end
  end

  describe "same_id?/2" do
    test "compares nodes by id" do
      id = NodeId.new("n1")
      a = Node.new(id, "hostA", 4001)
      b = %{Node.new(id, "hostB", 4002) | status: :down}
      c = Node.new(NodeId.new("n2"), "hostA", 4001)

      assert Node.same_id?(a, b)
      refute Node.same_id?(a, c)
    end
  end

  describe "id_value/1" do
    test "returns the id string" do
      node = Node.new(NodeId.new("node-9"), "h", 4000)
      assert Node.id_value(node) == "node-9"
    end
  end

  describe "id_starts_with?/2" do
    test "matches an id prefix" do
      node = Node.new(NodeId.new("eu-node-1"), "h", 4000)
      assert Node.id_starts_with?(node, "eu-")
      refute Node.id_starts_with?(node, "us-")
    end
  end

  describe "namespace/1" do
    test "returns the id namespace" do
      node = Node.new(NodeId.new("eu-node-1"), "h", 4000)
      assert Node.namespace(node) == "eu"
    end
  end

  describe "fresh?/2" do
    test "reflects heartbeat recency; never-seen is not fresh" do
      node = Node.new(NodeId.new("n1"), "h", 4000)
      assert Node.fresh?(node, 60_000)

      old = %{node | last_seen_at: DateTime.add(DateTime.utc_now(), -100, :second)}
      refute Node.fresh?(old, 1_000)

      never = %{node | last_seen_at: nil}
      refute Node.fresh?(never, 60_000)
    end
  end
end
