defmodule Replication.FollowerDurabilityTest do
  @moduledoc """
  The follower applies replicated entries to its local WAL when it is running,
  so a follower's copy is durable too.
  """

  use ExUnit.Case, async: false

  alias Replication.Follower
  alias Replication.ValueObjects.ReplicationOffset
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{SegmentManager, Writer}

  setup do
    dir = Path.join(System.tmp_dir!(), "shanghai_follower_durability_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    # start_supervised! gives synchronous, deterministic teardown so the named
    # `Storage.WAL.Writer` singleton never lingers into another test module.
    start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

    start_supervised!(
      {Writer,
       [
         data_dir: dir,
         node_id: "follower_node",
         segment_size_threshold: 10 * 1024 * 1024,
         segment_time_threshold: 3600
       ]}
    )

    group = "follower-durability-#{:rand.uniform(999_999)}"
    start_supervised!({Follower, group_id: group})

    on_exit(fn ->
      Enum.each(SegmentManager.list_segments(), fn {id, _pid} -> SegmentManager.stop_segment(id) end)
      File.rm_rf(dir)
    end)

    {:ok, group: group}
  end

  test "applying entries advances the WAL log", %{group: group} do
    {:ok, %{current_lsn: before_lsn}} = Writer.info()

    Follower.apply_entry(group, ReplicationOffset.new(1), "payload-1")
    Follower.apply_entry(group, ReplicationOffset.new(2), "payload-2")

    # Sync: a call drains the follower mailbox behind the casts above.
    offset = Follower.current_offset(group)
    assert offset.value == 2

    {:ok, %{current_lsn: after_lsn}} = Writer.info()
    assert after_lsn == before_lsn + 2
  end
end
