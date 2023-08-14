defmodule Storage.WAL.WriterTelemetryTest do
  @moduledoc "The WAL write hot path emits telemetry (observable by default)."

  use ExUnit.Case, async: false

  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{SegmentManager, Writer}

  @event [:shanghai, :storage, :wal, :write]

  setup do
    Storage.WALTestInfra.ensure_started()

    dir = Path.join(System.tmp_dir!(), "shanghai_writer_tel_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

    start_supervised!(
      {Writer,
       [
         data_dir: dir,
         node_id: "tel_node",
         segment_size_threshold: 10 * 1024 * 1024,
         segment_time_threshold: 3600
       ]}
    )

    handler_id = "wal-write-telemetry-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      Enum.each(SegmentManager.list_segments(), fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(dir)
    end)

    :ok
  end

  test "append emits a WAL write event with duration and bytes" do
    {:ok, _lsn} = Writer.append("hello shanghai")

    assert_receive {:telemetry, @event, measurements, metadata}
    assert is_number(measurements.duration) and measurements.duration >= 0
    assert is_integer(measurements.bytes) and measurements.bytes > 0
    assert is_integer(metadata.segment_id)
  end
end
