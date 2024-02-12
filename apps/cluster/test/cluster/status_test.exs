defmodule Cluster.StatusTest do
  @moduledoc "Cluster.status/0 summary against live membership."

  use ExUnit.Case, async: false

  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  setup_all do
    # The cluster app omits its `mod:` under the test env; start it explicitly.
    case Cluster.Application.start(:normal, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "status/0 reflects a joined node and cleans up on leave" do
    before = Cluster.status()

    assert %NodeId{} = before.local_node_id
    assert is_integer(before.node_count)
    assert is_integer(before.up)
    assert is_boolean(before.quorum_available)
    assert Cluster.quorum_available?() == before.quorum_available
    assert is_integer(before.quorum_size)
    assert is_integer(before.fault_tolerance)
    assert before.fault_tolerance == Cluster.fault_tolerance()
    assert is_float(before.health_ratio)
    assert is_boolean(Cluster.healthy?())
    assert is_float(Cluster.health_ratio())
    assert Cluster.health_ratio() >= 0.0 and Cluster.health_ratio() <= 1.0
    assert is_list(Cluster.node_ids())
    assert is_list(Cluster.node_addresses())

    id = NodeId.new("status-test-#{:rand.uniform(999_999)}")
    :ok = Cluster.join(Node.new(id, "localhost", 4321))

    after_join = Cluster.status()
    assert after_join.node_count == before.node_count + 1
    assert after_join.up == before.up + 1

    :ok = Cluster.leave(id)
    assert Cluster.status().node_count == before.node_count
  end

  test "local_node/0 returns the local entity or nil" do
    local = Cluster.local_node()
    assert local == nil or match?(%Node{}, local)

    if local, do: assert(local.id == Cluster.local_node_id())
  end

  test "topology/0 returns a serializable snapshot" do
    topo = Cluster.topology()

    assert is_integer(topo.node_count)
    assert is_list(topo.nodes)
    assert Map.has_key?(topo.status_summary, :up)
    assert Enum.all?(topo.nodes, &is_map/1)
  end

  test "member?/1 and up_nodes/0 track membership" do
    id = NodeId.new("member-test-#{:rand.uniform(999_999)}")
    refute Cluster.member?(id)

    :ok = Cluster.join(Node.new(id, "localhost", 4322))

    assert Cluster.member?(id)
    assert Enum.any?(Cluster.up_nodes(), &(&1.id == id))
    assert is_list(Cluster.down_nodes())
    assert is_list(Cluster.suspect_nodes())
    refute Enum.any?(Cluster.down_nodes(), &(&1.id == id))

    :ok = Cluster.leave(id)
    refute Cluster.member?(id)
  end
end
