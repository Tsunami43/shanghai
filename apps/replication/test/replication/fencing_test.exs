defmodule Replication.FencingTest do
  @moduledoc """
  Fencing on the data path: a follower must refuse entries from a leader that
  has been superseded.

  This is the half of the scheme that protects data already written. The quorum
  vote stops a second leader from being elected; fencing stops the *old* leader
  from continuing to write to followers that have moved on.
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

    group_id = "fencing-#{:rand.uniform(1_000_000)}"

    {:ok, _pid} =
      start_supervised(
        {Follower, [group_id: group_id, node_id: NodeId.new("f1")]},
        id: {Follower, group_id}
      )

    on_exit(fn -> Epoch.forget(group_id) end)

    {:ok, group_id: group_id}
  end

  describe "stale epoch rejection" do
    test "an entry from an older epoch is dropped", %{group_id: group_id} do
      # A newer leader has been elected in epoch 5.
      Epoch.observe(group_id, 5)

      Follower.apply_entry(group_id, ReplicationOffset.new(1), "from-old-leader", 4)
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 0,
             "an entry from a superseded leader must not be applied"
    end

    test "an entry from the current epoch is applied", %{group_id: group_id} do
      Epoch.observe(group_id, 5)

      Follower.apply_entry(group_id, ReplicationOffset.new(1), "from-current-leader", 5)
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 1
    end

    test "an entry from a newer epoch is applied and advances the fence", %{group_id: group_id} do
      Epoch.observe(group_id, 5)

      Follower.apply_entry(group_id, ReplicationOffset.new(1), "from-newer-leader", 9)
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 1
      assert Epoch.current(group_id) == 9
    end

    test "the old leader is locked out once a newer epoch has been seen", %{group_id: group_id} do
      # The new leader writes first, which raises this follower's fence...
      Follower.apply_entry(group_id, ReplicationOffset.new(1), "new-leader", 2)
      Process.sleep(50)
      assert Follower.current_offset(group_id).value == 1

      # ...so the deposed leader's in-flight entry is refused rather than
      # overwriting what the new leader wrote.
      Follower.apply_entry(group_id, ReplicationOffset.new(2), "deposed-leader", 1)
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 1,
             "the deposed leader must not be able to advance the follower"
    end

    test "entries without an epoch are accepted (unfenced group)", %{group_id: group_id} do
      # A group with no configured member list runs unfenced; the 3-arity call
      # is also what a node predating fencing would send.
      Follower.apply_entry(group_id, ReplicationOffset.new(1), "unfenced")
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 1
    end

    test "an unfenced entry is still accepted after an epoch has been seen", %{group_id: group_id} do
      Epoch.observe(group_id, 3)

      Follower.apply_entry(group_id, ReplicationOffset.new(1), "unfenced")
      Process.sleep(50)

      assert Follower.current_offset(group_id).value == 1,
             "nil epoch means no fencing information, not a stale epoch"
    end
  end

  defp ensure_started(fun) do
    case fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
