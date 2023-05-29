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
  end
end
