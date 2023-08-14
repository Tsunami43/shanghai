defmodule Storage.BenchmarkTest do
  @moduledoc """
  Smoke tests for the WAL benchmark helpers. Small counts exercise the
  sub-millisecond / zero-division guards.
  """

  use ExUnit.Case, async: false

  alias Storage.Benchmark
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{SegmentManager, Writer}

  setup do
    Storage.WALTestInfra.ensure_started()

    dir = Path.join(System.tmp_dir!(), "shanghai_bench_test_#{:rand.uniform(999_999)}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    start_supervised!({SegmentIndex, data_dir: Path.join(dir, "index")})

    start_supervised!(
      {Writer,
       [
         data_dir: dir,
         node_id: "bench_node",
         segment_size_threshold: 10 * 1024 * 1024,
         segment_time_threshold: 3600
       ]}
    )

    on_exit(fn ->
      Enum.each(SegmentManager.list_segments(), fn {id, _pid} ->
        SegmentManager.stop_segment(id)
      end)

      File.rm_rf(dir)
    end)

    :ok
  end

  test "wal_write_throughput returns a well-formed result" do
    result = Benchmark.wal_write_throughput(20)

    assert result.total_writes == 20
    assert result.successful == 20
    assert result.failed == 0
    assert is_integer(result.throughput_per_sec) and result.throughput_per_sec >= 0
    assert is_number(result.avg_latency_ms)
  end

  test "wal_write_latency reports percentiles" do
    result = Benchmark.wal_write_latency(20)

    assert result.count == 20
    assert is_number(result.p50)
    assert is_number(result.p99)
    assert is_number(result.max)
  end

  test "concurrent_writes aggregates across processes" do
    result = Benchmark.concurrent_writes(2, 10)

    assert result.total_writes == 20
    assert is_integer(result.throughput_per_sec) and result.throughput_per_sec >= 0
    assert is_number(result.avg_latency_ms)
  end
end
