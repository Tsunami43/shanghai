defmodule Replication.FollowerOrderingTest do
  @moduledoc """
  The follower only applies the next expected entry: a gap triggers catch-up
  without advancing, and an already-applied (old) entry is ignored. Runs in
  in-memory mode (no WAL configured).
  """

  use ExUnit.Case, async: false

  alias Replication.Follower
  alias Replication.ValueObjects.ReplicationOffset

  setup do
    group = "follower-ordering-#{:rand.uniform(999_999)}"
    follower = start_supervised!({Follower, group_id: group})
    {:ok, group: group, follower: follower}
  end

  test "a gap does not advance the offset", %{group: group} do
    # current offset is 0, next expected is 1; offset 3 is a gap.
    Follower.apply_entry(group, ReplicationOffset.new(3), "payload")

    # current_offset/1 is a call and drains the cast above.
    assert Follower.current_offset(group).value == 0
  end

  test "the next expected entry advances the offset", %{group: group} do
    Follower.apply_entry(group, ReplicationOffset.new(1), "payload")
    assert Follower.current_offset(group).value == 1
  end

  test "an already-applied (old) entry is ignored", %{group: group} do
    Follower.apply_entry(group, ReplicationOffset.new(1), "payload")
    assert Follower.current_offset(group).value == 1

    # Re-sending offset 1 (not greater than current) is ignored.
    Follower.apply_entry(group, ReplicationOffset.new(1), "payload")
    assert Follower.current_offset(group).value == 1
  end
end
