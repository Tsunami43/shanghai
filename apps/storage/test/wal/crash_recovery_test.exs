defmodule Storage.WAL.CrashRecoveryTest do
  @moduledoc """
  End-to-end crash recovery: after a restart that lost the WAL metadata and the
  flushed segment index, the writer must recover its position from the segment
  files themselves (the source of truth) and resume appending without clobbering
  the records already on disk.
  """

  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @test_dir Path.join(System.tmp_dir!(), "shanghai_crash_recovery_#{:rand.uniform(999_999)}")

  setup_all do
    Storage.WALTestInfra.ensure_started()
    :ok
  end

  setup do
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf(@test_dir) end)
    :ok
  end

  defp segments_dir, do: Path.join(@test_dir, "segments")
  defp index_dir, do: Path.join(@test_dir, "index")

  defp start_stack do
    {:ok, index} = SegmentIndex.start_link(data_dir: index_dir(), segments_dir: segments_dir())

    {:ok, writer} =
      Writer.start_link(data_dir: @test_dir, node_id: "test_node", segment_size_threshold: 1024)

    {:ok, reader} = Reader.start_link([])
    %{index: index, writer: writer, reader: reader}
  end

  defp stop_stack(%{index: index, writer: writer, reader: reader}) do
    for pid <- [reader, writer, index], Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    # Stop the shared segment processes so the restart reopens them from disk.
    SegmentManager.list_segments()
    |> Enum.each(fn {id, _pid} -> SegmentManager.stop_segment(id) end)
  end

  defp simulate_crash_loss do
    # A crash before the periodic flush leaves neither the metadata nor the index
    # file on disk — only the segments.
    File.rm(Path.join(@test_dir, "wal_metadata.dat"))
    File.rm_rf(index_dir())
  end

  test "recovers the write position and data from segments after metadata/index loss" do
    stack = start_stack()

    assert {:ok, 0} = Writer.append("rec-a")
    assert {:ok, 1} = Writer.append("rec-b")
    assert {:ok, 2} = Writer.append("rec-c")

    stop_stack(stack)
    simulate_crash_loss()

    # Restart: the index rebuilds from segments and the writer recovers position.
    _stack2 = start_stack()

    assert {:ok, %{current_lsn: 3}} = Writer.info()
    assert SegmentIndex.max_lsn() == 2

    # New appends continue after the recovered records rather than overwriting.
    assert {:ok, 3} = Writer.append("rec-d")

    # All records, old and new, are readable.
    assert {:ok, entries} = Reader.read_range(0, 3)
    assert Enum.map(entries, & &1.data) == ["rec-a", "rec-b", "rec-c", "rec-d"]

    stop_stack(_stack2)
  end
end
