defmodule Replication.ElectionRestrictionTest do
  @moduledoc """
  The election up-to-date check uses a follower's real (epoch, offset) position,
  so a candidate cannot win against a voter whose log is fresher.

  This exercises the whole path end to end: a follower applies entries stamped
  with an epoch, reports its position, and a candidate is judged against it.
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.{Epoch, Follower}
  alias Replication.ValueObjects.ReplicationOffset

  setup do
    ensure_started(fn -> Registry.start_link(keys: :unique, name: Replication.Registry) end)

    unless Process.whereis(Epoch) do
      start_supervised!(Epoch)
    end

    group = "election-restriction-#{:rand.uniform(1_000_000)}"

    {:ok, _} =
      start_supervised({Follower, [group_id: group, node_id: NodeId.new("f1")]},
        id: {Follower, group}
      )

    on_exit(fn -> Epoch.forget(group) end)
    {:ok, group: group}
  end

  test "a follower reports its position as {last_epoch, offset}", %{group: group} do
    assert {0, %{value: 0}} = Follower.position(group)

    Follower.apply_entry(group, ReplicationOffset.new(1), "a", 3)
    Process.sleep(30)

    assert {3, %{value: 1}} = Follower.position(group)
  end

  test "a candidate from a staler epoch is refused against this follower", %{group: group} do
    # The follower has applied up to (epoch 5, offset 2).
    Follower.apply_entry(group, ReplicationOffset.new(1), "a", 5)
    Follower.apply_entry(group, ReplicationOffset.new(2), "b", 5)
    Process.sleep(30)

    voter_position = Follower.position(group)

    # A candidate with a longer log but a staler last epoch must lose.
    assert {:denied, :behind_log} =
             Epoch.grant_vote(group, 6, NodeId.new("cand"),
               candidate_position: {4, ReplicationOffset.new(50)},
               local_position: voter_position
             )
  end

  test "a candidate at least as up-to-date is granted", %{group: group} do
    Follower.apply_entry(group, ReplicationOffset.new(1), "a", 5)
    Process.sleep(30)

    assert :granted =
             Epoch.grant_vote(group, 6, NodeId.new("cand"),
               candidate_position: {5, ReplicationOffset.new(1)},
               local_position: Follower.position(group)
             )
  end

  defp ensure_started(fun) do
    case fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
