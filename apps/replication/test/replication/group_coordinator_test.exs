defmodule Replication.GroupCoordinatorTest do
  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.{Follower, GroupCoordinator, Leader, Stream}

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    :ok
  end

  test "reconciles this node's group role as membership changes (failover)" do
    group_id = "coord-#{:rand.uniform(1_000_000)}"
    [n1, n2, n3] = [NodeId.new("n1"), NodeId.new("n2"), NodeId.new("n3")]

    # A mutable membership source we can drive from the test.
    {:ok, up} = Agent.start_link(fn -> [n1, n2, n3] end)
    up_fun = fn -> Agent.get(up, & &1) end

    {:ok, coord} =
      GroupCoordinator.start_link(
        group_id: group_id,
        this_node: n2,
        members: [n1, n2, n3],
        up_nodes: up_fun,
        # These members are fictional, so no real vote can reach them. This test
        # covers role reconciliation, not quorum; quorum has its own tests.
        elect: fn _group, _members, _candidate -> {:ok, 1} end,
        batch_size: 1
      )

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      stop_group_children()
    end)

    # All up: n1 is the smallest, so this node (n2) is a follower.
    assert GroupCoordinator.current_role(group_id) == :follower
    assert %{value: 0} = Follower.current_offset(group_id)
    assert catch_exit(Leader.current_offset(group_id))

    # n1 goes down: n2 becomes the smallest up member and is promoted to leader.
    Agent.update(up, fn _ -> [n2, n3] end)
    assert {:ok, :leader} = GroupCoordinator.reconcile(group_id)
    assert %{value: 0} = Leader.current_offset(group_id)
    assert catch_exit(Follower.current_offset(group_id))
    assert follower_ids(group_id) == ["n3"]

    # n1 comes back: it is the smallest again, so n2 is demoted back to a follower.
    Agent.update(up, fn _ -> [n1, n2, n3] end)
    assert {:ok, :follower} = GroupCoordinator.reconcile(group_id)
    assert %{value: 0} = Follower.current_offset(group_id)
    assert catch_exit(Leader.current_offset(group_id))

    # n2 itself drops out of the up set: the group has no role here anymore.
    Agent.update(up, fn _ -> [n1, n3] end)
    assert {:ok, :none} = GroupCoordinator.reconcile(group_id)
    assert catch_exit(Follower.current_offset(group_id))
    assert [] = DynamicSupervisor.which_children(Replication.GroupSupervisor)
  end

  test "a stable membership does not churn the role" do
    group_id = "coord-stable-#{:rand.uniform(1_000_000)}"
    [n1, n2] = [NodeId.new("n1"), NodeId.new("n2")]

    {:ok, coord} =
      GroupCoordinator.start_link(
        group_id: group_id,
        this_node: n1,
        up_nodes: [n1, n2],
        batch_size: 1
      )

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      stop_group_children()
    end)

    assert GroupCoordinator.current_role(group_id) == :leader
    assert GroupCoordinator.leader(group_id) == n1
    leader_pid = leader_pid(group_id)

    # Reconciling against the same membership must not restart the leader.
    assert {:ok, :leader} = GroupCoordinator.reconcile(group_id)
    assert leader_pid(group_id) == leader_pid
  end

  test "emits role_changed telemetry and reports roles via local_group_roles/0" do
    group_id = "coord-obs-#{:rand.uniform(1_000_000)}"
    [n1, n2] = [NodeId.new("n1"), NodeId.new("n2")]

    handler_id = "role-changed-#{:rand.uniform(1_000_000)}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:shanghai, :replication, :role_changed],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:role_changed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, coord} =
      GroupCoordinator.start_link(group_id: group_id, this_node: n1, up_nodes: [n1, n2])

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      stop_group_children()
    end)

    # n1 is the smallest member, so this node becomes the leader, one event.
    assert_receive {:role_changed, %{count: 1},
                    %{group_id: ^group_id, role: :leader, leader: "n1"}}

    # The role is queryable across this node's coordinators.
    assert Replication.local_group_roles()[group_id] == :leader
  end

  defp follower_ids(group_id) do
    group_id |> Stream.get_follower_states() |> Map.keys() |> Enum.map(& &1.value) |> Enum.sort()
  end

  defp leader_pid(group_id) do
    [{pid, _}] = Registry.lookup(Replication.Registry, {:leader, group_id})
    pid
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
