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
