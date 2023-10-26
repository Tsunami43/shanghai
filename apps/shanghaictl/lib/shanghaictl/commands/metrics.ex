defmodule Shanghaictl.Commands.Metrics do
  @moduledoc """
  Metrics command for viewing performance and operational metrics.
  """

  @doc """
  Shows operational metrics including WAL, replication, and heartbeat stats.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case get_metrics(admin_url) do
      {:ok, metrics} -> render(metrics, format)
      {:error, :not_connected} -> display_not_connected()
      {:error, reason} -> display_error(reason)
    end
  end

  defp render(metrics, :json), do: IO.puts(Jason.encode!(metrics))

  defp render(metrics, :text) do
    IO.puts("Shanghai Operational Metrics")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")
    display_metrics(metrics)
  end

  defp get_metrics(admin_url) do
    case Req.get("#{admin_url}/api/v1/metrics") do
      {:ok, %{status: 200, body: metrics}} ->
        {:ok, metrics}

      {:ok, %{status: status}} ->
        {:error, "API returned status #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, :not_connected}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp display_metrics(metrics) do
    display_wal_metrics(metrics["wal"])
    display_storage_metrics(metrics["storage"])
    display_store_metrics(metrics["store"])
    display_query_metrics(metrics["query"])
    display_compaction_metrics(metrics["compaction"])
    display_replication_metrics(metrics["replication"])
    display_heartbeat_metrics(metrics["heartbeat"])
    display_membership_change(metrics["last_membership_change"])
  end

  defp display_query_metrics(query) do
    query
    |> query_lines()
    |> Enum.each(&IO.puts/1)

    IO.puts("")
  end

  defp display_compaction_metrics(compaction) do
    compaction
    |> compaction_lines()
    |> Enum.each(&IO.puts/1)

    IO.puts("")
  end

  @doc false
  @spec compaction_lines(map() | nil) :: [String.t()]
  def compaction_lines(%{"count" => count} = stats) do
    [
      "Compaction:",
      "  Runs: #{count}",
      "  Last Duration: #{format_float(Map.get(stats, "last_duration_ms", 0))}ms",
      "  Bytes Reclaimed: #{Map.get(stats, "bytes_reclaimed", 0)}"
    ]
  end

  def compaction_lines(_), do: ["Compaction: No data"]

  @doc false
  @spec query_lines(map() | nil) :: [String.t()]
  def query_lines(query) when is_map(query) and map_size(query) > 0 do
    header = "Query Operations:"

    rows =
      query
      |> Enum.sort_by(fn {op, _stat} -> op end)
      |> Enum.map(fn {op, stat} ->
        "  #{op}: #{Map.get(stat, "count", 0)} ops, avg #{format_float(Map.get(stat, "avg", 0))}ms, " <>
          "#{Map.get(stat, "errors", 0)} errors"
      end)

    [header | rows]
  end

  def query_lines(_), do: ["Query Operations: No data"]

  defp display_storage_metrics(storage) do
    storage
    |> storage_lines()
    |> Enum.each(&IO.puts/1)

    IO.puts("")
  end

  @doc false
  @spec storage_lines(map() | nil) :: [String.t()]
  def storage_lines(storage) when is_map(storage) and map_size(storage) > 0 do
    [
      "Storage (WAL):",
      "  Running: #{Map.get(storage, "wal_running")}",
      "  Segments: #{Map.get(storage, "segments", Map.get(storage, "active_segments"))}",
      "  Current LSN: #{Map.get(storage, "current_lsn")}",
      "  Entries: #{Map.get(storage, "entries")}",
      "  Size: #{Map.get(storage, "bytes")} bytes",
      "  Snapshots: #{Map.get(storage, "snapshots")}"
    ]
  end

  def storage_lines(_), do: ["Storage (WAL): No data"]

  defp display_store_metrics(store) do
    store
    |> store_lines()
    |> Enum.each(&IO.puts/1)

    IO.puts("")
  end

  @doc false
  @spec store_lines(map() | nil) :: [String.t()]
  def store_lines(%{"store" => store, "cache" => cache})
      when is_map(store) and is_map(cache) do
    [
      "Store Metrics:",
      "  Durable: #{Map.get(store, "durable")}",
      "  Recovered: #{Map.get(store, "recovered")}",
      "  Keys: #{Map.get(store, "size")}",
      "  Memory: #{Map.get(store, "memory_bytes")} bytes",
      "  Cache:",
      "    Size: #{Map.get(cache, "size")}/#{Map.get(cache, "max_size")}",
      "    TTL: #{format_ttl(Map.get(cache, "ttl_ms"))}",
      "    Hits: #{Map.get(cache, "hits")}",
      "    Misses: #{Map.get(cache, "misses")}",
      "    Hit Ratio: #{format_float(Map.get(cache, "hit_ratio"))}"
    ]
  end

  def store_lines(_), do: ["Store Metrics: No data"]

  defp display_wal_metrics(%{"writes" => writes, "syncs" => syncs}) do
    IO.puts("WAL Metrics:")

    if map_size(writes) > 0 do
      IO.puts("  Writes:")
      IO.puts("    Count: #{writes["count"]}")
      IO.puts("    Avg Duration: #{format_float(writes["avg"])}ms")
      IO.puts("    Min: #{format_float(writes["min"])}ms")
      IO.puts("    Max: #{format_float(writes["max"])}ms")
    else
      IO.puts("  Writes: No data")
    end

    if map_size(syncs) > 0 do
      IO.puts("  Syncs:")
      IO.puts("    Count: #{syncs["count"]}")
      IO.puts("    Avg Duration: #{format_float(syncs["avg"])}ms")
      IO.puts("    Min: #{format_float(syncs["min"])}ms")
      IO.puts("    Max: #{format_float(syncs["max"])}ms")
    else
      IO.puts("  Syncs: No data")
    end

    IO.puts("")
  end

  defp display_wal_metrics(_), do: IO.puts("WAL Metrics: No data\n")

  defp display_replication_metrics(replication_lags) when is_map(replication_lags) do
    IO.puts("Replication Lag:")

    if map_size(replication_lags) > 0 do
      Enum.each(replication_lags, fn {key, stats} ->
        IO.puts("  #{key}:")
        IO.puts("    Count: #{stats["count"]}")
        IO.puts("    Avg Lag: #{format_float(stats["avg"])} offsets")
        IO.puts("    Max Lag: #{format_float(stats["max"])} offsets")
      end)
    else
      IO.puts("  No replication lag data")
    end

    IO.puts("")
  end

  defp display_replication_metrics(_), do: IO.puts("Replication Lag: No data\n")

  defp display_heartbeat_metrics(heartbeats) when is_map(heartbeats) do
    IO.puts("Heartbeat RTT:")

    if map_size(heartbeats) > 0 do
      Enum.each(heartbeats, fn {key, stats} ->
        IO.puts("  #{key}:")
        IO.puts("    Count: #{stats["count"]}")
        IO.puts("    Avg RTT: #{format_float(stats["avg"])}ms")
        IO.puts("    Min: #{format_float(stats["min"])}ms")
        IO.puts("    Max: #{format_float(stats["max"])}ms")
      end)
    else
      IO.puts("  No heartbeat data")
    end

    IO.puts("")
  end

  defp display_heartbeat_metrics(_), do: IO.puts("Heartbeat RTT: No data\n")

  defp display_membership_change(nil) do
    IO.puts("Last Membership Change: None")
  end

  defp display_membership_change(change) do
    IO.puts("Last Membership Change:")
    IO.puts("  Event: #{change["event_type"]}")
    IO.puts("  Node: #{change["node_id"]}")
    IO.puts("  Node Count: #{change["node_count"]}")
    IO.puts("  Timestamp: #{change["timestamp"]}")
  end

  defp display_not_connected do
    IO.puts("Error: Not connected to cluster")
    IO.puts("Ensure Shanghai node is running and accessible.")
    System.halt(1)
  end

  defp display_error(reason) do
    IO.puts("Error: #{reason}")
    System.halt(1)
  end

  defp format_float(value) when is_float(value), do: Float.round(value, 2)
  defp format_float(value), do: value

  defp format_ttl(nil), do: "none"
  defp format_ttl(ms), do: "#{ms}ms"
end
