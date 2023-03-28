defmodule Replication.PerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance

  alias CoreDomain.Types.NodeId
  alias Replication.Leader

  setup do
    case Process.whereis(Replication.Registry) do
      nil -> start_supervised!({Registry, keys: :unique, name: Replication.Registry})
      _pid -> :ok
    end

    :ok
  end

  describe "Write throughput" do
    @tag :skip
    test "local writes achieve high throughput" do
      group_id = "perf-group"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 1]})

      # Warm up
      for _ <- 1..100 do
        Leader.write(group_id, "warmup", consistency_level: :local)
      end

      # Measure throughput
      count = 1000
      start_time = System.monotonic_time(:millisecond)

      for _ <- 1..count do
        {:ok, _} = Leader.write(group_id, "data", consistency_level: :local)
      end

      elapsed = System.monotonic_time(:millisecond) - start_time
      throughput = count / (elapsed / 1000)

      IO.puts("Local write throughput: #{Float.round(throughput, 2)} writes/sec")
      assert throughput > 500, "Expected >500 writes/sec, got #{throughput}"
    end
  end

  describe "Latency" do
    @tag :skip
    test "local writes have low latency" do
      group_id = "latency-group"
      leader_id = NodeId.new("leader")

      start_supervised!({Leader, [group_id: group_id, node_id: leader_id, replica_count: 1]})

      # Measure latencies
      latencies =
        for _ <- 1..100 do
          start = System.monotonic_time(:microsecond)
          {:ok, _} = Leader.write(group_id, "data", consistency_level: :local)
          System.monotonic_time(:microsecond) - start
        end

      avg_latency = Enum.sum(latencies) / length(latencies) / 1000
      p99_latency = Enum.at(Enum.sort(latencies), 98) / 1000

      IO.puts("Average latency: #{Float.round(avg_latency, 2)}ms")
      IO.puts("P99 latency: #{Float.round(p99_latency, 2)}ms")

      assert avg_latency < 5, "Expected avg <5ms, got #{avg_latency}ms"
      assert p99_latency < 20, "Expected p99 <20ms, got #{p99_latency}ms"
    end
  end
end
