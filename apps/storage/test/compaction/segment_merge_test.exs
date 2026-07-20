defmodule Storage.Compaction.SegmentMergeTest do
  @moduledoc """
  End-to-end segment merge: several rotated segments are rewritten into one
  file, and every entry must still be readable at its original LSN afterwards.

  A merge that loses or reorders records is worse than no compaction at all, so
  these tests read the data back rather than trusting the compactor's own log.
  """

  use ExUnit.Case, async: false

  alias Storage.Compaction.Compactor
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @test_dir Path.join(System.tmp_dir!(), "shanghai_segment_merge_#{:rand.uniform(999_999)}")

  setup_all do
    Storage.WALTestInfra.ensure_started()
    :ok
  end

  setup do
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      SegmentManager.list_segments()
      |> Enum.each(fn {id, _pid} -> SegmentManager.stop_segment(id) end)

      File.rm_rf(@test_dir)
    end)

    :ok
  end

  defp segments_dir, do: Path.join(@test_dir, "segments")
  defp index_dir, do: Path.join(@test_dir, "index")

  # A small size threshold makes the writer rotate every few appends, so a
  # handful of writes is enough to produce a compactable group.
  defp start_stack(segment_size_threshold) do
    {:ok, index} = SegmentIndex.start_link(data_dir: index_dir(), segments_dir: segments_dir())

    {:ok, writer} =
      Writer.start_link(
        data_dir: @test_dir,
        node_id: "test_node",
        segment_size_threshold: segment_size_threshold
      )

    {:ok, reader} = Reader.start_link([])

    # The storage app already runs a supervised Compactor under the module
    # name, so this one registers separately.
    {:ok, compactor} =
      Compactor.start_link(
        name: __MODULE__.TestCompactor,
        data_dir: @test_dir,
        strategy: __MODULE__.MergeEverything
      )

    on_exit(fn ->
      for pid <- [compactor, reader, writer, index], Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp write_entries(count) do
    for i <- 1..count do
      {:ok, lsn} = Writer.append("entry-#{i}-#{String.duplicate("x", 64)}")
      {lsn, "entry-#{i}-#{String.duplicate("x", 64)}"}
    end
  end

  defp compact_and_wait do
    :ok = Compactor.compact(__MODULE__.TestCompactor)

    # The run happens in a Task; wait for the compactor to report itself idle.
    Enum.reduce_while(1..100, :timeout, fn _, _ ->
      Process.sleep(20)

      case Compactor.stats(__MODULE__.TestCompactor) do
        {:ok, %{in_progress: false, last_compaction: %DateTime{}}} -> {:halt, :ok}
        _ -> {:cont, :timeout}
      end
    end)
  end

  defp segment_file_count do
    case File.ls(segments_dir()) do
      {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".wal"))
      {:error, _} -> 0
    end
  end

  describe "segment merge" do
    test "every entry is still readable at its original LSN after a merge" do
      start_stack(512)
      written = write_entries(12)

      assert segment_file_count() > 1, "expected the writer to have rotated segments"

      assert compact_and_wait() == :ok

      for {lsn, data} <- written do
        assert {:ok, entry} = Reader.read(lsn),
               "LSN #{lsn} became unreadable after compaction"

        assert entry.data == data, "LSN #{lsn} came back with the wrong payload"
      end
    end

    test "the group collapses into a single segment file" do
      start_stack(512)
      write_entries(12)

      before_count = segment_file_count()
      assert before_count > 1

      assert compact_and_wait() == :ok

      assert segment_file_count() < before_count,
             "compaction did not reduce the number of segment files"

      refute File.ls!(segments_dir()) |> Enum.any?(&String.ends_with?(&1, ".compacting")),
             "a temporary compaction file was left behind"
    end

    test "the writer keeps appending across a compaction run" do
      start_stack(512)
      first = write_entries(12)

      assert compact_and_wait() == :ok

      # The active segment is excluded from compaction, so the writer's position
      # must survive the run untouched.
      second = write_entries(4)

      for {lsn, data} <- first ++ second do
        assert {:ok, entry} = Reader.read(lsn)
        assert entry.data == data
      end
    end

    test "compaction emits a telemetry event with the reclaimed byte counts" do
      handler_id = "compaction-telemetry-#{:rand.uniform(999_999)}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:shanghai, :storage, :compaction, :complete],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:compaction_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_stack(512)
      write_entries(12)

      assert compact_and_wait() == :ok

      assert_receive {:compaction_event, measurements, metadata}, 1_000

      assert measurements.duration_ms >= 0
      assert measurements.bytes_before > 0
      assert measurements.bytes_after > 0

      # Merging drops the per-segment headers, so the result is smaller than the
      # sum of its sources while still holding every entry.
      assert measurements.bytes_after < measurements.bytes_before
      assert length(metadata.segment_ids) > 1
    end
  end

  defmodule MergeEverything do
    @moduledoc """
    Test strategy that merges every available segment into one group, so the
    test does not depend on the size-tiering thresholds.
    """

    @behaviour Storage.Compaction.Strategy

    @impl true
    def select_segments(segment_infos) when length(segment_infos) > 1 do
      [segment_infos |> Enum.map(& &1.id) |> Enum.sort()]
    end

    def select_segments(_segment_infos), do: []
  end
end
