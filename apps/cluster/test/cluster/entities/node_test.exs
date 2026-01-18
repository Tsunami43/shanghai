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
    test "marks a down node as up" do
      node_id = NodeId.new("node1")
      node = Node.new(node_id, "localhost", 4000)
      down_node = Node.mark_down(node)

      up_node = Node.mark_up(down_node)

      assert up_node.status == :up
      assert up_node.last_seen_at != down_node.last_seen_at
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
end
