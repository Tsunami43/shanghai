defmodule Replication.EpochTest do
  @moduledoc """
  Voting rules for leadership epochs.

  These are the safety conditions the whole fencing scheme rests on, so the
  tests state them as properties: one vote per epoch, no vote for a candidate
  that is behind, and an epoch that never moves backwards.
  """

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Epoch
  alias Replication.ValueObjects.ReplicationOffset

  setup do
    unless Process.whereis(Epoch) do
      start_supervised!(Epoch)
    end

    group = "epoch-test-#{:rand.uniform(1_000_000)}"
    on_exit(fn -> Epoch.forget(group) end)
    {:ok, group: group}
  end

  describe "current/1 and observe/2" do
    test "an unknown group starts at epoch 0", %{group: group} do
      assert Epoch.current(group) == 0
    end

    test "observing a higher epoch advances it", %{group: group} do
      assert Epoch.observe(group, 5) == 5
      assert Epoch.current(group) == 5
    end

    test "observing a lower epoch does not move it backwards", %{group: group} do
      Epoch.observe(group, 7)

      assert Epoch.observe(group, 3) == 7
      assert Epoch.current(group) == 7
    end

    test "a newer epoch clears the vote cast in an older one", %{group: group} do
      assert :granted = Epoch.grant_vote(group, 1, NodeId.new("a"))
      assert Epoch.voted_for(group) == NodeId.new("a")

      Epoch.observe(group, 2)
      assert Epoch.voted_for(group) == nil
    end
  end

  describe "grant_vote/4 - one vote per epoch" do
    test "grants a vote for a higher epoch", %{group: group} do
      assert :granted = Epoch.grant_vote(group, 1, NodeId.new("a"))
      assert Epoch.current(group) == 1
      assert Epoch.voted_for(group) == NodeId.new("a")
    end

    test "refuses a second candidate in the same epoch", %{group: group} do
      assert :granted = Epoch.grant_vote(group, 1, NodeId.new("a"))

      assert {:denied, :already_voted} = Epoch.grant_vote(group, 1, NodeId.new("b"))
      assert Epoch.voted_for(group) == NodeId.new("a"), "the original vote must stand"
    end

    test "refuses an epoch below the highest seen", %{group: group} do
      Epoch.observe(group, 5)

      assert {:denied, :stale_epoch} = Epoch.grant_vote(group, 4, NodeId.new("a"))
    end

    test "refuses an epoch equal to one already seen without a vote", %{group: group} do
      # A leader was observed in epoch 5, so 5 is spent even though this node
      # never voted in it.
      Epoch.observe(group, 5)

      assert {:denied, :already_voted} = Epoch.grant_vote(group, 5, NodeId.new("a"))
    end

    test "a later epoch is still grantable after a vote", %{group: group} do
      assert :granted = Epoch.grant_vote(group, 1, NodeId.new("a"))
      assert :granted = Epoch.grant_vote(group, 2, NodeId.new("b"))

      assert Epoch.current(group) == 2
      assert Epoch.voted_for(group) == NodeId.new("b")
    end

    test "two candidates in one epoch cannot both be granted", %{group: group} do
      candidates = for i <- 1..10, do: NodeId.new("c#{i}")

      results = Enum.map(candidates, fn c -> Epoch.grant_vote(group, 3, c) end)

      assert Enum.count(results, &(&1 == :granted)) == 1,
             "exactly one candidate may win a given epoch"
    end
  end

  describe "grant_vote/4 - log completeness" do
    test "refuses a candidate whose offset is behind this node", %{group: group} do
      assert {:denied, :behind_log} =
               Epoch.grant_vote(group, 1, NodeId.new("a"),
                 candidate_offset: ReplicationOffset.new(3),
                 local_offset: ReplicationOffset.new(7)
               )

      assert Epoch.current(group) == 0, "a denied vote must not advance the epoch"
    end

    test "grants when the candidate is level with this node", %{group: group} do
      assert :granted =
               Epoch.grant_vote(group, 1, NodeId.new("a"),
                 candidate_offset: ReplicationOffset.new(7),
                 local_offset: ReplicationOffset.new(7)
               )
    end

    test "grants when the candidate is ahead", %{group: group} do
      assert :granted =
               Epoch.grant_vote(group, 1, NodeId.new("a"),
                 candidate_offset: ReplicationOffset.new(9),
                 local_offset: ReplicationOffset.new(7)
               )
    end

    test "skips the check when either offset is unknown", %{group: group} do
      assert :granted =
               Epoch.grant_vote(group, 1, NodeId.new("a"), local_offset: ReplicationOffset.new(7))
    end
  end

  describe "forget/1" do
    test "drops the group's epoch and vote", %{group: group} do
      Epoch.grant_vote(group, 4, NodeId.new("a"))

      assert :ok = Epoch.forget(group)
      assert Epoch.current(group) == 0
      assert Epoch.voted_for(group) == nil
    end
  end
end
