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

    id = NodeId.new("status-test-#{:rand.uniform(999_999)}")
    :ok = Cluster.join(Node.new(id, "localhost", 4321))

    after_join = Cluster.status()
    assert after_join.node_count == before.node_count + 1
    assert after_join.up == before.up + 1

    :ok = Cluster.leave(id)
    assert Cluster.status().node_count == before.node_count
  end

  test "member?/1 and up_nodes/0 track membership" do
    id = NodeId.new("member-test-#{:rand.uniform(999_999)}")
    refute Cluster.member?(id)

    :ok = Cluster.join(Node.new(id, "localhost", 4322))

    assert Cluster.member?(id)
    assert Enum.any?(Cluster.up_nodes(), &(&1.id == id))

    :ok = Cluster.leave(id)
    refute Cluster.member?(id)
  end
end
