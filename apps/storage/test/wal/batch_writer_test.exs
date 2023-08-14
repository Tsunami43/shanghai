defmodule Storage.WAL.BatchWriterTest do
  @moduledoc "Batching layer over a WAL segment."

  use ExUnit.Case, async: false

  alias CoreDomain.Entities.LogEntry
  alias CoreDomain.Types.{LogSequenceNumber, NodeId}
  alias Storage.WAL.{BatchWriter, Segment, SegmentManager}

  setup do
    Storage.WALTestInfra.ensure_started()

    dir = Path.join(System.tmp_dir!(), "shanghai_batch_test_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    seg_id = :rand.uniform(1_000_000)
    path = Path.join(dir, "segment_#{seg_id}.wal")
    {:ok, segment} = SegmentManager.start_segment(seg_id, 0, path)

    start_supervised!({BatchWriter, segment_pid: segment, batch_timeout_ms: 30})

    on_exit(fn ->
      SegmentManager.stop_segment(seg_id)
      File.rm_rf(dir)
    end)

    {:ok, segment: segment}
  end

  defp entry(lsn),
    do: LogEntry.new(LogSequenceNumber.new(lsn), "payload-#{lsn}", %NodeId{value: "n"}, %{})

  test "append flushes on the batch timeout and returns an offset" do
    assert {:ok, offset} = BatchWriter.append(entry(0))
    assert is_integer(offset)
  end

  test "flush/0 flushes pending writes immediately" do
    parent = self()

    task = Task.async(fn -> send(parent, {:result, BatchWriter.append(entry(1))}) end)
    # Give the append time to queue before flushing.
    Process.sleep(5)
    assert :ok = BatchWriter.flush()

    assert_receive {:result, {:ok, offset}}, 1000
    assert is_integer(offset)
    Task.await(task)
  end

  test "a batched write is durable and readable from the segment", %{segment: segment} do
    assert {:ok, offset} = BatchWriter.append(entry(7))

    # The write was made via append_entry_no_sync and flushed with a single
    # fsync; it must be readable at its offset.
    assert {:ok, read} = Segment.read_entry(segment, offset)
    assert read.data == "payload-7"
  end
end
