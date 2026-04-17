defmodule Replication.GroupCoordinatorMembershipTest do
  @moduledoc """
  Integration: the coordinator reads a *real* `Cluster.Membership` (not an
  injected node source) and reacts to genuine join/leave cluster events,
  reconciling this node's replication role as the membership changes.
  """

  use ExUnit.Case, async: false

  alias Cluster.Entities.Node
  alias Cluster.Membership
  alias CoreDomain.Types.NodeId
  alias Replication.GroupCoordinator

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    start_supervised!({Membership, node_id: NodeId.new("n2")})
    :ok
  end

  test "role follows real membership join/leave events" do
    [n1, n2, n3] = [NodeId.new("n1"), NodeId.new("n2"), NodeId.new("n3")]
    for id <- [n1, n2, n3], do: :ok = Membership.join_node(Node.new(id, "localhost", 0))

    group_id = "coord-mem-#{:rand.uniform(1_000_000)}"

    {:ok, coord} =
      GroupCoordinator.start_link(group_id: group_id, this_node: n2, batch_size: 1)

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      stop_group_children()
    end)

    # All members up: n1 is the smallest, so n2 is a follower.
    assert GroupCoordinator.current_role(group_id) == :follower

    # n1 leaves the cluster: the coordinator observes the event and promotes n2.
    :ok = Membership.leave_node(n1)
    assert wait_until(fn -> GroupCoordinator.current_role(group_id) == :leader end)

    # n1 rejoins: n2 is demoted back to a follower.
    :ok = Membership.join_node(Node.new(n1, "localhost", 0))
    assert wait_until(fn -> GroupCoordinator.current_role(group_id) == :follower end)
  end

  defp wait_until(fun, retries \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, retries - 1)
    end
  end

  defp ensure_started(start_fun) do
    case start_fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stop_group_children do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Replication.GroupSupervisor) do
      DynamicSupervisor.terminate_child(Replication.GroupSupervisor, pid)
    end
  end
end
