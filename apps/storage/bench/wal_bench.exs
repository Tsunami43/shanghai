# WAL write benchmark: group commit vs one fsync per write.
#
# Run it:
#
#     BENCH_DIR=~/.cache/shanghai_bench MIX_ENV=test elixir -S mix run \
#       apps/storage/bench/wal_bench.exs
#
# BENCH_DIR MUST point at a real filesystem. /tmp is tmpfs on most Linux
# systems, where fsync is a memory barrier rather than a disk flush and the
# results are inflated by orders of magnitude. Check with `df -T <dir>`.
#
# `batch_size: 1` forces one fsync per append, reproducing the behaviour from
# before group commit, so the two columns are directly comparable.
#
# Results from one run are recorded in docs/PERFORMANCE.md; every number is
# storage-bound, so re-measure rather than trusting them.
require Logger
Logger.configure(level: :warning)

alias Storage.Index.SegmentIndex
alias Storage.WAL.{SegmentManager, Writer}

bench_root =
  System.get_env("BENCH_DIR") ||
    raise "set BENCH_DIR to a directory on a real (non-tmpfs) filesystem"

defmodule B do
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{SegmentManager, Writer}

  def setup(root, opts) do
    dir = Path.join(root, "run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, index} =
      SegmentIndex.start_link(
        data_dir: Path.join(dir, "index"),
        segments_dir: Path.join(dir, "segments")
      )

    {:ok, writer} =
      Writer.start_link(
        Keyword.merge(
          [
            data_dir: dir,
            node_id: "bench",
            # 256 MB: keep rotation out of the measurement
            segment_size_threshold: 256 * 1024 * 1024
          ],
          opts
        )
      )

    {dir, index, writer}
  end

  def teardown({dir, index, writer}) do
    for pid <- [writer, index], Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    SegmentManager.list_segments()
    |> Enum.each(fn {id, _pid} -> SegmentManager.stop_segment(id) end)

    File.rm_rf(dir)
  end

  # One fsync per append is the pre-group-commit baseline.
  def sequential(root, opts, count) do
    ctx = setup(root, opts)
    data = :crypto.strong_rand_bytes(1024)

    # Warm up the segment file and the page cache.
    for _ <- 1..100, do: Writer.append(data)

    t0 = System.monotonic_time(:microsecond)
    for _ <- 1..count, do: {:ok, _} = Writer.append(data)
    us = System.monotonic_time(:microsecond) - t0

    teardown(ctx)
    %{throughput: trunc(count * 1_000_000 / us), us_per_write: Float.round(us / count, 1)}
  end

  def concurrent(root, opts, procs, per_proc) do
    ctx = setup(root, opts)
    data = :crypto.strong_rand_bytes(1024)
    for _ <- 1..100, do: Writer.append(data)

    t0 = System.monotonic_time(:microsecond)

    1..procs
    |> Enum.map(fn _ ->
      Task.async(fn -> for _ <- 1..per_proc, do: {:ok, _} = Writer.append(data) end)
    end)
    |> Task.await_many(:infinity)

    us = System.monotonic_time(:microsecond) - t0
    total = procs * per_proc

    teardown(ctx)
    %{throughput: trunc(total * 1_000_000 / us), us_per_write: Float.round(us / total, 1)}
  end

  def latency(root, opts, count) do
    ctx = setup(root, opts)
    data = :crypto.strong_rand_bytes(1024)
    for _ <- 1..100, do: Writer.append(data)

    samples =
      for _ <- 1..count do
        t0 = System.monotonic_time(:microsecond)
        {:ok, _} = Writer.append(data)
        System.monotonic_time(:microsecond) - t0
      end

    teardown(ctx)
    sorted = Enum.sort(samples)
    at = fn p -> Enum.at(sorted, min(trunc(length(sorted) * p), length(sorted) - 1)) / 1000 end
    %{p50: Float.round(at.(0.50), 3), p95: Float.round(at.(0.95), 3), p99: Float.round(at.(0.99), 3)}
  end
end

IO.puts("\n=== SEQUENTIAL (1 process, 1 KB writes, 2000 writes) ===")

for bs <- [1, 100] do
  r = B.sequential(bench_root, [batch_size: bs], 2_000)
  IO.puts("batch_size=#{bs}: #{r.throughput} writes/sec (#{r.us_per_write} us/write)")
end

IO.puts("\n=== CONCURRENT (1 KB writes, 200 writes per process) ===")
IO.puts("procs | batch_size=1 (one fsync/write) | batch_size=100 (group commit)")

for procs <- [1, 10, 50, 100] do
  per = 200
  a = B.concurrent(bench_root, [batch_size: 1], procs, per)
  b = B.concurrent(bench_root, [batch_size: 100], procs, per)
  IO.puts("#{String.pad_leading(to_string(procs), 5)} | #{String.pad_leading(to_string(a.throughput), 10)}/sec | #{String.pad_leading(to_string(b.throughput), 10)}/sec")
end

IO.puts("\n=== BATCH SIZE SWEEP (50 concurrent processes, 200 writes each) ===")

for bs <- [1, 10, 50, 100, 500] do
  r = B.concurrent(bench_root, [batch_size: bs], 50, 200)
  IO.puts("batch_size=#{String.pad_leading(to_string(bs), 4)}: #{String.pad_leading(to_string(r.throughput), 8)} writes/sec")
end

IO.puts("\n=== LATENCY (single writer, 1000 samples, ms) ===")
l = B.latency(bench_root, [batch_size: 100], 1_000)
IO.puts("P50=#{l.p50}  P95=#{l.p95}  P99=#{l.p99}")
IO.puts("")
