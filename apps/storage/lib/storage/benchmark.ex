defmodule Storage.Benchmark do
  @moduledoc """
  Performance benchmarking utilities for Storage subsystem.

  Provides benchmarks for:
  - WAL write throughput
  - WAL sync latency
  - Compaction performance
  - Read latency

  ## Usage

      # WAL write benchmark
      Storage.Benchmark.wal_write_throughput(10_000)

      # Latency percentiles
      Storage.Benchmark.wal_write_latency(1_000)
  """

  require Logger
  alias Storage.WAL.Writer

  @doc """
  Measures WAL write throughput.

  Performs the specified number of writes and reports throughput.

  ## Examples

      iex> Storage.Benchmark.wal_write_throughput(10_000)
      %{
        total_writes: 10_000,
        duration_ms: 850,
        throughput: 11_764,
        avg_latency_ms: 0.085
      }
  """
  @spec wal_write_throughput(pos_integer()) :: map()
  def wal_write_throughput(count) do
    Logger.info("Starting WAL write throughput benchmark (#{count} writes)")

    # 1 KB per write
    data = :crypto.strong_rand_bytes(1024)

    start_time = System.monotonic_time(:millisecond)

    results =
      1..count
      |> Enum.map(fn _ ->
        case Writer.append(data) do
          {:ok, _lsn} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    success_count = Enum.count(results, &(&1 == :ok))
    failure_count = Enum.count(results, &(elem(&1, 0) == :error))

    throughput = trunc(success_count / (duration_ms / 1000))
    avg_latency_ms = duration_ms / success_count

    result = %{
      total_writes: count,
      successful: success_count,
      failed: failure_count,
      duration_ms: duration_ms,
      throughput_per_sec: throughput,
      avg_latency_ms: Float.round(avg_latency_ms, 3)
    }

    Logger.info("Benchmark complete: #{throughput} writes/sec, avg latency: #{avg_latency_ms}ms")

    result
  end

  @doc """
  Measures WAL write latency percentiles.

  Performs writes and calculates P50, P95, P99 latency.

  ## Examples

      iex> Storage.Benchmark.wal_write_latency(1_000)
      %{
        p50: 0.8,
        p95: 2.1,
        p99: 4.5,
        max: 8.2
      }
  """
  @spec wal_write_latency(pos_integer()) :: map()
  def wal_write_latency(count) do
    Logger.info("Starting WAL write latency benchmark (#{count} writes)")

    data = :crypto.strong_rand_bytes(1024)

    latencies =
      1..count
      |> Enum.map(fn _ ->
        start = System.monotonic_time(:microsecond)

        case Writer.append(data) do
          {:ok, _lsn} ->
            duration = System.monotonic_time(:microsecond) - start
            # Convert to milliseconds
            duration / 1000

          {:error, _reason} ->
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.sort()

    p50 = percentile(latencies, 0.50)
    p95 = percentile(latencies, 0.95)
    p99 = percentile(latencies, 0.99)
    max = List.last(latencies)

    result = %{
      count: length(latencies),
      p50: Float.round(p50, 2),
      p95: Float.round(p95, 2),
      p99: Float.round(p99, 2),
      max: Float.round(max, 2)
    }

    Logger.info(
      "Latency percentiles - P50: #{result.p50}ms, P95: #{result.p95}ms, P99: #{result.p99}ms"
    )

    result
  end

  @doc """
  Measures concurrent write performance.

  Spawns multiple processes writing simultaneously.
  """
  @spec concurrent_writes(pos_integer(), pos_integer()) :: map()
  def concurrent_writes(num_processes, writes_per_process) do
    Logger.info(
      "Starting concurrent write benchmark (#{num_processes} processes, #{writes_per_process} writes each)"
    )

    start_time = System.monotonic_time(:millisecond)

    tasks =
      1..num_processes
      |> Enum.map(fn _ ->
        Task.async(fn ->
          data = :crypto.strong_rand_bytes(1024)

          Enum.reduce(1..writes_per_process, 0, fn _, acc ->
            case Writer.append(data) do
              {:ok, _lsn} -> acc + 1
              {:error, _} -> acc
            end
          end)
        end)
      end)

    results = Task.await_many(tasks, :infinity)
    end_time = System.monotonic_time(:millisecond)

    duration_ms = end_time - start_time
    total_writes = Enum.sum(results)
    throughput = trunc(total_writes / (duration_ms / 1000))

    result = %{
      num_processes: num_processes,
      writes_per_process: writes_per_process,
      total_writes: total_writes,
      duration_ms: duration_ms,
      throughput_per_sec: throughput,
      avg_latency_ms: Float.round(duration_ms / total_writes, 3)
    }

    Logger.info(
      "Concurrent benchmark complete: #{throughput} writes/sec across #{num_processes} processes"
    )

    result
  end

  @doc """
  Generates a benchmark report comparing different configurations.
  """
  @spec generate_report() :: :ok
  def generate_report do
    Logger.info("=== Shanghai Storage Benchmark Report ===\n")

    # Sequential writes
    Logger.info("1. Sequential Writes (10,000 writes)")
    seq_result = wal_write_throughput(10_000)
    Logger.info("Sequential Result: #{inspect(seq_result)}")

    :timer.sleep(2000)

    # Latency percentiles
    Logger.info("\n2. Latency Percentiles (1,000 writes)")
    lat_result = wal_write_latency(1_000)
    Logger.info("Latency Result: #{inspect(lat_result)}")

    :timer.sleep(2000)

    # Concurrent writes
    Logger.info("\n3. Concurrent Writes (10 processes × 1,000 writes)")
    conc_result = concurrent_writes(10, 1_000)
    Logger.info("Concurrent Result: #{inspect(conc_result)}")

    Logger.info("\n=== Benchmark Complete ===")

    :ok
  end

  ## Private Functions

  defp percentile(sorted_list, percentile) when percentile >= 0 and percentile <= 1 do
    count = length(sorted_list)
    index = trunc(count * percentile)
    index = max(0, min(index, count - 1))
    Enum.at(sorted_list, index)
  end
end
