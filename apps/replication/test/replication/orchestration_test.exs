defmodule Replication.OrchestrationTest do
  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.{Follower, Leader, Stream}

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    ensure_started(fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Replication.GroupSupervisor)
    end)

    :ok
  end

  test "start_leader/2 brings up both the stream and the leader for a group" do
    group_id = "orch-leader-#{:rand.uniform(1_000_000)}"

    assert {:ok, _leader} =
             Replication.start_leader(group_id,
               node_id: NodeId.new("leader"),
               replica_count: 1,
               batch_size: 1
             )

    on_exit(fn -> stop_group_children() end)

    # Both processes are up: the leader accepts writes and the stream tracks state.
    assert %{value: 0} = Leader.current_offset(group_id)
    assert %{} = Stream.get_follower_states(group_id)

    # A local-consistency write goes through the leader and advances the offset.
    assert {:ok, %{value: 1}} = Leader.write(group_id, "data", consistency_level: :local)
  end

  test "start_follower/2 brings up a follower for a group" do
    group_id = "orch-follower-#{:rand.uniform(1_000_000)}"

    assert {:ok, _follower} =
             Replication.start_follower(group_id, node_id: NodeId.new("follower"))

    on_exit(fn -> stop_group_children() end)

    assert %{value: 0} = Follower.current_offset(group_id)
  end

  test "start_group/2 on the leader member brings up the leader and registers followers" do
    group_id = "orch-group-lead-#{:rand.uniform(1_000_000)}"
    members = [NodeId.new("n1"), NodeId.new("n2"), NodeId.new("n3")]

    # n1 is the smallest id, so it is the deterministic leader.
    assert {:ok, pid} =
             Replication.start_group(group_id,
               members: members,
               this_node: NodeId.new("n1"),
               batch_size: 1
             )

    assert is_pid(pid)
    on_exit(fn -> stop_group_children() end)

    # The leader is up and accepts writes.
    assert %{value: 0} = Leader.current_offset(group_id)
    assert {:ok, %{value: 1}} = Leader.write(group_id, "data", consistency_level: :local)

    # The other two members are registered as follower targets on the stream.
    follower_ids =
      group_id
      |> Stream.get_follower_states()
      |> Map.keys()
      |> Enum.map(& &1.value)
      |> Enum.sort()

    assert follower_ids == ["n2", "n3"]
  end

  test "start_group/2 on a non-leader member brings up a follower" do
    group_id = "orch-group-fol-#{:rand.uniform(1_000_000)}"
    members = [NodeId.new("n1"), NodeId.new("n2")]

    assert {:ok, pid} =
             Replication.start_group(group_id, members: members, this_node: NodeId.new("n2"))

    assert is_pid(pid)
    on_exit(fn -> stop_group_children() end)

    # A follower is running for the group; no leader/stream was started here.
    assert %{value: 0} = Follower.current_offset(group_id)
    assert catch_exit(Leader.current_offset(group_id))
  end

  test "start_group/2 on a non-member starts nothing" do
    group_id = "orch-group-none-#{:rand.uniform(1_000_000)}"
    members = [NodeId.new("n1"), NodeId.new("n2")]

    assert {:ok, :not_a_member} =
             Replication.start_group(group_id, members: members, this_node: NodeId.new("n9"))

    assert [] = DynamicSupervisor.which_children(Replication.GroupSupervisor)
  end

  test "start_group/2 with no members returns an error" do
    assert {:error, :no_members} = Replication.start_group("orch-group-empty", members: [])
  end

  test "start_group/2 honours an explicit leader_id over the smallest id" do
    group_id = "orch-group-explicit-#{:rand.uniform(1_000_000)}"
    members = [NodeId.new("n1"), NodeId.new("n2"), NodeId.new("n3")]

    # Force n2 as leader even though n1 has the smallest id.
    assert {:ok, _pid} =
             Replication.start_group(group_id,
               members: members,
               leader_id: NodeId.new("n2"),
               this_node: NodeId.new("n2"),
               batch_size: 1
             )

    on_exit(fn -> stop_group_children() end)

    assert %{value: 0} = Leader.current_offset(group_id)

    follower_ids =
      group_id
      |> Stream.get_follower_states()
      |> Map.keys()
      |> Enum.map(& &1.value)
      |> Enum.sort()

    assert follower_ids == ["n1", "n3"]
  end

  test "configured_groups/0 normalizes and filters the :groups config" do
    previous = Application.get_env(:replication, :groups)

    Application.put_env(:replication, :groups, [
      [id: "g1", batch_size: 5],
      %{id: "g2", persist_wal: false},
      [batch_size: 9],
      [group_id: "g3"]
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:replication, :groups, previous),
        else: Application.delete_env(:replication, :groups)
    end)

    groups = Replication.configured_groups()

    # The entry with neither :id nor :group_id is dropped; :id becomes :group_id.
    assert Enum.map(groups, &Keyword.fetch!(&1, :group_id)) == ["g1", "g2", "g3"]
    assert Keyword.fetch!(hd(groups), :batch_size) == 5
    refute Keyword.has_key?(hd(groups), :id)
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
