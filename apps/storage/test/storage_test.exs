defmodule StorageTest do
  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  doctest Storage

  test "info/0 summarizes the storage subsystem" do
    info = Storage.info()

    assert is_boolean(info.wal_running)
    assert is_integer(info.active_segments)
    assert info.active_segments >= 0
    assert is_integer(info.current_lsn)
    assert info.current_lsn >= 0
  end

  test "list_snapshots/0 is [] when the snapshot manager is not running" do
    refute is_pid(Process.whereis(Storage.Snapshot.Manager))
    assert Storage.list_snapshots() == []
  end

  describe "with a running WAL" do
    setup do
      Storage.WALTestInfra.ensure_started()

      dir = Path.join(System.tmp_dir!(), "shanghai_storage_facade_#{:rand.uniform(999_999)}")
      File.rm_rf(dir)
      File.mkdir_p!(dir)

      start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

      start_supervised!(
        {Writer,
         [
           data_dir: dir,
           node_id: "facade_node",
           segment_size_threshold: 10 * 1024 * 1024,
           segment_time_threshold: 3600
         ]}
      )

      start_supervised!({Reader, []})

      on_exit(fn ->
        Enum.each(SegmentManager.list_segments(), fn {id, _pid} ->
          SegmentManager.stop_segment(id)
        end)

        File.rm_rf(dir)
      end)

      :ok
    end

    test "append/1 and read/1 round-trip through the facade" do
      assert {:ok, lsn} = Storage.append("hello facade")

      # Let the index catch up.
      Process.sleep(10)

      assert {:ok, entry} = Storage.read(lsn)
      assert entry.data == "hello facade"
    end

    test "info/0 reports the WAL as running" do
      info = Storage.info()

      assert info.wal_running == true
      assert info.active_segments >= 1
    end

    test "read_range/2 round-trips a batch of entries through the facade" do
      {:ok, first} = Storage.append("range-a")
      {:ok, _second} = Storage.append("range-b")
      {:ok, last} = Storage.append("range-c")

      # Let the index catch up.
      Process.sleep(10)

      assert {:ok, entries} = Storage.read_range(first, last)
      assert Enum.map(entries, & &1.data) == ["range-a", "range-b", "range-c"]
    end

    test "info/0 advances current_lsn as entries are appended" do
      before = Storage.info().current_lsn
      {:ok, _lsn} = Storage.append("advance")
      Process.sleep(10)

      assert Storage.info().current_lsn > before
    end

    test "wal_stats/0 aggregates segment count, entries and bytes" do
      {:ok, _lsn} = Storage.append("stat-entry")
      Process.sleep(10)

      stats = Storage.wal_stats()
      assert stats.segments >= 1
      assert stats.entries >= 1
      assert stats.bytes > 0
    end
  end
end
