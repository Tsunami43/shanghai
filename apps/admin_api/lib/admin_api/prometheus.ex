defmodule AdminApi.Prometheus do
  @moduledoc """
  Renders Shanghai runtime metrics in the Prometheus text exposition format
  (version 0.0.4). Data is pulled from `Observability.MetricsReporter` and the
  live cluster state.

  Exposed via `GET /metrics`.
  """

  @doc """
  Returns the full metrics page as an iodata-backed string.
  """
  @spec render() :: iodata()
  def render do
    [
      wal_metrics(),
      query_metrics(),
      cache_metrics(),
      replication_metrics(),
      heartbeat_metrics(),
      cluster_metrics()
    ]
  end

  # --- Query metrics (per-operation count and total duration) ---

  defp query_metrics do
    ops = safe(fn -> Observability.MetricsReporter.get_query_stats() end, %{})

    header = [
      "# HELP shanghai_query_operations_total Query operations by type.\n",
      "# TYPE shanghai_query_operations_total counter\n"
    ]

    rows =
      Enum.map(ops, fn {operation, stat} ->
        count = Map.get(stat, :count, 0)
        ["shanghai_query_operations_total{operation=\"", to_string(operation), "\"} ", num(count), "\n"]
      end)

    [header | rows]
  end

  # --- Query read-cache metrics (from the live cache stats) ---

  defp cache_metrics do
    stats = safe(fn -> elem(Query.Cache.stats(), 1) end, %{})

    [
      gauge(
        "shanghai_query_cache_size",
        "Number of entries currently in the query read cache.",
        Map.get(stats, :size, 0)
      ),
      gauge(
        "shanghai_query_cache_hit_ratio",
        "Query read-cache hit ratio since start (0..1).",
        Map.get(stats, :hit_ratio, 0.0)
      ),
      counter(
        "shanghai_query_cache_hits_total",
        "Total query read-cache hits.",
        Map.get(stats, :hits, 0)
      ),
      counter(
        "shanghai_query_cache_misses_total",
        "Total query read-cache misses.",
        Map.get(stats, :misses, 0)
      )
    ]
  end

  # --- WAL metrics (from the telemetry aggregator) ---

  defp wal_metrics do
    stats = safe(fn -> Observability.MetricsReporter.get_wal_stats() end, %{})
    writes = Map.get(stats, :writes, %{})
    syncs = Map.get(stats, :syncs, %{})

    [
      counter(
        "shanghai_wal_writes_total",
        "Total WAL writes recorded.",
        stat_count(writes)
      ),
      summary(
        "shanghai_wal_write_duration_ms",
        "WAL write duration in milliseconds.",
        stat_count(writes),
        stat_sum(writes)
      ),
      summary(
        "shanghai_wal_sync_duration_ms",
        "WAL fsync duration in milliseconds.",
        stat_count(syncs),
        stat_sum(syncs)
      )
    ]
  end

  # --- Replication metrics (aggregated lag per group/follower) ---

  defp replication_metrics do
    lags = safe(fn -> Observability.MetricsReporter.get_replication_stats() end, %{})

    header = [
      "# HELP shanghai_replication_lag Average follower offset lag behind the leader.\n",
      "# TYPE shanghai_replication_lag gauge\n"
    ]

    rows =
      Enum.map(lags, fn {key, stat} ->
        avg = Map.get(stat, :avg, 0)
        ["shanghai_replication_lag{follower=\"", key, "\"} ", num(avg), "\n"]
      end)

    [header | rows]
  end

  # --- Heartbeat metrics (aggregated RTT per node link) ---

  defp heartbeat_metrics do
    beats = safe(fn -> Observability.MetricsReporter.get_heartbeat_stats() end, %{})

    header = [
      "# HELP shanghai_cluster_heartbeat_rtt Average heartbeat round-trip time in ms.\n",
      "# TYPE shanghai_cluster_heartbeat_rtt gauge\n"
    ]

    rows =
      Enum.map(beats, fn {link, stat} ->
        avg = Map.get(stat, :avg, 0)
        ["shanghai_cluster_heartbeat_rtt{link=\"", link, "\"} ", num(avg), "\n"]
      end)

    [header | rows]
  end

  # --- Cluster metrics (from live membership state) ---

  defp cluster_metrics do
    counts =
      safe(
        fn ->
          cluster = Cluster.cluster_state()

          %{
            "up" => Cluster.State.status_count(cluster, :up),
            "suspect" => Cluster.State.status_count(cluster, :suspect),
            "down" => Cluster.State.status_count(cluster, :down)
          }
        end,
        %{"up" => 0, "suspect" => 0, "down" => 0}
      )

    header = [
      "# HELP shanghai_cluster_nodes Number of cluster nodes by status.\n",
      "# TYPE shanghai_cluster_nodes gauge\n"
    ]

    rows =
      Enum.map(counts, fn {status, count} ->
        ["shanghai_cluster_nodes{status=\"", status, "\"} ", Integer.to_string(count), "\n"]
      end)

    [header | rows]
  end

  # --- Prometheus line helpers ---

  defp counter(name, help, value) do
    [
      "# HELP ", name, " ", help, "\n",
      "# TYPE ", name, " counter\n",
      name, " ", num(value), "\n"
    ]
  end

  defp gauge(name, help, value) do
    [
      "# HELP ", name, " ", help, "\n",
      "# TYPE ", name, " gauge\n",
      name, " ", num(value), "\n"
    ]
  end

  defp summary(name, help, count, sum) do
    [
      "# HELP ", name, " ", help, "\n",
      "# TYPE ", name, " summary\n",
      name, "_sum ", num(sum), "\n",
      name, "_count ", num(count), "\n"
    ]
  end

  defp stat_count(stat), do: Map.get(stat, :count, 0)
  defp stat_sum(stat), do: Map.get(stat, :sum, 0)

  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value) when is_float(value), do: Float.to_string(value)
  defp num(value), do: to_string(value)

  # Runs `fun`, returning `default` if the required process/state isn't available.
  defp safe(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end
end
