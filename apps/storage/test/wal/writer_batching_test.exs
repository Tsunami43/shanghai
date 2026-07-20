defmodule Storage.WAL.WriterBatchingTest do
  @moduledoc """
  Group commit in the WAL writer: concurrent appends must share an fsync, while
  every caller still only gets its reply once its entry is actually on disk.

  The interesting property is not "fewer syncs" on its own - it is fewer syncs
  *without* losing entries, so these tests read the data back too.
  """

  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Reader, SegmentManager, Writer}

  @test_dir Path.join(System.tmp_dir!(), "shanghai_writer_batching_#{:rand.uniform(999_999)}")

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

  defp start_stack(opts \\ []) do
    {:ok, index} =
      SegmentIndex.start_link(
        data_dir: Path.join(@test_dir, "index"),
        segments_dir: Path.join(@test_dir, "segments")
      )

    writer_opts =
      Keyword.merge(
        [data_dir: @test_dir, node_id: "test_node", segment_size_threshold: 1_000_000],
        opts
      )

    {:ok, writer} = Writer.start_link(writer_opts)
    {:ok, reader} = Reader.start_link([])

    on_exit(fn ->
      for pid <- [reader, writer, index], Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp count_sync_events(fun) do
    handler_id = "sync-count-#{:rand.uniform(999_999)}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:shanghai, :storage, :wal, :sync],
      fn _event, _measurements, _metadata, _config -> send(test_pid, :wal_sync) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)

    {result, drain_syncs(0)}
  end

  defp drain_syncs(count) do
    receive do
      :wal_sync -> drain_syncs(count + 1)
    after
      0 -> count
    end
  end

  describe "group commit" do
    test "concurrent appends share an fsync without losing entries" do
      start_stack()
      writers = 50

      {lsns, sync_count} =
        count_sync_events(fn ->
          1..writers
          |> Task.async_stream(fn i -> Writer.append("concurrent-#{i}") end,
            max_concurrency: writers,
            timeout: 10_000
          )
          |> Enum.map(fn {:ok, {:ok, lsn}} -> lsn end)
        end)

      assert length(lsns) == writers
      assert length(Enum.uniq(lsns)) == writers, "LSNs must be unique across concurrent writers"

      # In practice this run collapses to a single fsync; allow headroom for
      # scheduling variance while still failing loudly if batching regresses.
      assert sync_count <= div(writers, 2),
             "expected batching to amortize fsync, got #{sync_count} syncs for #{writers} writes"

      # Every acknowledged write must be readable, whatever the batching did.
      for lsn <- lsns do
        assert {:ok, _entry} = Reader.read(lsn)
      end
    end

    test "a lone writer is not delayed by the batch timeout" do
      # A long timeout would dominate if the writer waited for it; group commit
      # flushes immediately when nothing else is queued.
      start_stack(batch_timeout_ms: 5_000)

      elapsed =
        fn ->
          for i <- 1..5, do: {:ok, _} = Writer.append("sequential-#{i}")
        end
        |> :timer.tc()
        |> elem(0)

      assert elapsed < 1_000_000,
             "sequential appends waited on the batch timer (#{div(elapsed, 1000)}ms)"
    end

    test "an acknowledged write survives a writer restart" do
      start_stack()

      lsns = for i <- 1..20, do: elem(Writer.append("durable-#{i}"), 1)

      # Stopping the writer runs terminate/2, which must flush anything pending.
      :ok = GenServer.stop(Writer)

      for lsn <- lsns do
        assert {:ok, entry} = Reader.read(lsn)
        assert entry.data =~ "durable-"
      end
    end

    test "pending writes are flushed before a rotation" do
      # A tiny threshold rotates almost every append, exercising the flush that
      # has to happen before the writer retargets its segment.
      start_stack(segment_size_threshold: 256)

      lsns = for i <- 1..15, do: elem(Writer.append("rotate-#{i}"), 1)

      assert length(Enum.uniq(lsns)) == 15

      for lsn <- lsns do
        assert {:ok, entry} = Reader.read(lsn),
               "LSN #{lsn} was lost across a rotation"

        assert entry.data =~ "rotate-"
      end
    end

    test "batch_size caps how many writes share one fsync" do
      start_stack(batch_size: 5, batch_timeout_ms: 5_000)
      writers = 40

      {_lsns, sync_count} =
        count_sync_events(fn ->
          1..writers
          |> Task.async_stream(fn i -> Writer.append("capped-#{i}") end,
            max_concurrency: writers,
            timeout: 10_000
          )
          |> Enum.map(fn {:ok, {:ok, lsn}} -> lsn end)
        end)

      # With a batch cap of 5, the run cannot be served by a single fsync.
      assert sync_count >= div(writers, 5) - 1,
             "batch_size did not cap the batch: #{sync_count} syncs for #{writers} writes"
    end
  end
end
