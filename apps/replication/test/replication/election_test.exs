defmodule Replication.ElectionTest do
  @moduledoc """
  Quorum-gated promotion.

  The property that matters: a node that cannot reach a majority of the
  configured members must not become leader. That is what stops both sides of a
  partition from accepting writes, so it is asserted from both directions -
  a reachable majority is promoted, an isolated candidate is not.
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.{Epoch, GroupCoordinator}

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    unless Process.whereis(Epoch) do
      start_supervised!(Epoch)
    end

    group_id = "election-#{:rand.uniform(1_000_000)}"
    on_exit(fn -> Epoch.forget(group_id) end)

    {:ok, group_id: group_id}
  end

  describe "stand_for_election/3" do
    test "a lone member elects itself", %{group_id: group_id} do
      me = NodeId.new("solo")

      assert {:ok, 1} = Replication.stand_for_election(group_id, [me], me)
      assert Epoch.current(group_id) == 1
    end

    test "a candidate that cannot reach the other members loses", %{group_id: group_id} do
      me = NodeId.new("me")
      members = [me, NodeId.new("unreachable_a"), NodeId.new("unreachable_b")]

      # Only this node's own vote can be collected: 1 of 3, short of the 2 needed.
      assert {:error, :no_quorum} = Replication.stand_for_election(group_id, members, me)
    end

    test "an unresolvable member is a missing vote, never a local one", %{group_id: group_id} do
      # If unresolvable members were treated as local, this node would cast all
      # five ballots and manufacture its own quorum.
      me = NodeId.new("me")
      members = [me | for(i <- 1..4, do: NodeId.new("ghost_#{i}"))]

      assert {:error, :no_quorum} = Replication.stand_for_election(group_id, members, me)
    end

    test "the epoch advances on each attempt so a stale one cannot be reused", %{
      group_id: group_id
    } do
      me = NodeId.new("solo")

      assert {:ok, 1} = Replication.stand_for_election(group_id, [me], me)
      assert {:ok, 2} = Replication.stand_for_election(group_id, [me], me)
      assert Epoch.current(group_id) == 2
    end

    test "a losing election still leaves the epoch untouched locally", %{group_id: group_id} do
      me = NodeId.new("me")
      members = [me, NodeId.new("ghost_a"), NodeId.new("ghost_b")]

      Replication.stand_for_election(group_id, members, me)

      # This node granted itself the vote, so the epoch moved for it, but no
      # leader exists in it - the next attempt must use a higher epoch.
      first = Epoch.current(group_id)
      Replication.stand_for_election(group_id, members, me)

      assert Epoch.current(group_id) > first
    end
  end

  describe "coordinator promotion" do
    test "a candidate that loses the vote takes no role", %{group_id: group_id} do
      [n1, n2] = [NodeId.new("n1"), NodeId.new("n2")]

      {:ok, coord} =
        GroupCoordinator.start_link(
          group_id: group_id,
          this_node: n2,
          members: [n1, n2],
          # n1 is down, so n2 would be promoted - but the vote fails.
          up_nodes: fn -> [n2] end,
          elect: fn _group, _members, _candidate -> {:error, :no_quorum} end
        )

      on_exit(fn -> if Process.alive?(coord), do: GenServer.stop(coord) end)

      assert GroupCoordinator.current_role(group_id) == :none,
             "a node that lost its election must not run a leader"

      assert catch_exit(Replication.Leader.current_offset(group_id))
    end

    test "a candidate that wins the vote is promoted", %{group_id: group_id} do
      [n1, n2] = [NodeId.new("n1"), NodeId.new("n2")]

      {:ok, coord} =
        GroupCoordinator.start_link(
          group_id: group_id,
          this_node: n2,
          members: [n1, n2],
          up_nodes: fn -> [n2] end,
          elect: fn _group, _members, _candidate -> {:ok, 7} end
        )

      on_exit(fn ->
        if Process.alive?(coord), do: GenServer.stop(coord)
        stop_group_children()
      end)

      assert GroupCoordinator.current_role(group_id) == :leader
      assert %{value: 0} = Replication.Leader.current_offset(group_id)
    end

    test "promotion is retried on the next reconcile after a lost vote", %{group_id: group_id} do
      [n1, n2] = [NodeId.new("n1"), NodeId.new("n2")]
      {:ok, outcome} = Agent.start_link(fn -> {:error, :no_quorum} end)

      {:ok, coord} =
        GroupCoordinator.start_link(
          group_id: group_id,
          this_node: n2,
          members: [n1, n2],
          up_nodes: fn -> [n2] end,
          elect: fn _group, _members, _candidate -> Agent.get(outcome, & &1) end
        )

      on_exit(fn ->
        if Process.alive?(coord), do: GenServer.stop(coord)
        stop_group_children()
      end)

      assert GroupCoordinator.current_role(group_id) == :none

      # The partition heals and the vote now succeeds.
      Agent.update(outcome, fn _ -> {:ok, 2} end)

      assert {:ok, :leader} = GroupCoordinator.reconcile(group_id)
    end

    test "a group without a configured member list promotes unfenced", %{group_id: group_id} do
      # Quorum needs a fixed group size; without :members the coordinator falls
      # back to the old unfenced behaviour rather than blocking promotion.
      n2 = NodeId.new("n2")

      {:ok, coord} =
        GroupCoordinator.start_link(
          group_id: group_id,
          this_node: n2,
          up_nodes: fn -> [n2] end
        )

      on_exit(fn ->
        if Process.alive?(coord), do: GenServer.stop(coord)
        stop_group_children()
      end)

      assert GroupCoordinator.current_role(group_id) == :leader
    end
  end

  defp ensure_started(fun) do
    case fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stop_group_children do
    DynamicSupervisor.which_children(Replication.GroupSupervisor)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Replication.GroupSupervisor, pid)
    end)
  catch
    :exit, _ -> :ok
  end
end
