defmodule Replication.LeaderDurabilityTest do
  @moduledoc """
  The leader persists writes to the storage WAL when it is running (a configured
  deployment), so acknowledged writes survive a crash.
  """

  use ExUnit.Case, async: false

  alias Replication.Leader
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{SegmentManager, Writer}

  setup do
    # The storage app already owns the segment Registry and SegmentManager; here
    # we start the SegmentIndex and a Writer so a real WAL is available.
    dir = Path.join(System.tmp_dir!(), "shanghai_leader_durability_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    # start_supervised! gives synchronous, deterministic teardown so the named
    # `Storage.WAL.Writer` singleton never lingers into another test module.
    start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

    start_supervised!(
      {Writer,
       [
         data_dir: dir,
         node_id: "leader_node",
         segment_size_threshold: 10 * 1024 * 1024,
         segment_time_threshold: 3600
       ]}
    )

    group = "durability-group-#{:rand.uniform(999_999)}"
    start_supervised!({Leader, group_id: group, replica_count: 1})

    on_exit(fn ->
      Enum.each(SegmentManager.list_segments(), fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(dir)
    end)

    {:ok, group: group}
  end

  test "a leader write advances the WAL log", %{group: group} do
    {:ok, %{current_lsn: before_lsn}} = Writer.info()

    assert {:ok, _offset} = Leader.write(group, "payload-1", consistency_level: :local)
    assert {:ok, _offset} = Leader.write(group, "payload-2", consistency_level: :local)

    {:ok, %{current_lsn: after_lsn}} = Writer.info()
    assert after_lsn == before_lsn + 2
  end
end
