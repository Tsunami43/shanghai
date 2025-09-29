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
      storage_metrics(),
      query_metrics(),
      cache_metrics(),
      replication_metrics(),
      heartbeat_metrics(),
      cluster_metrics()
    ]
  end

  # --- Storage subsystem gauges (from the live facade summary) ---

  defp storage_metrics do
    info = safe(fn -> Storage.info() end, %{})
    wal = safe(fn -> Storage.wal_stats() end, %{})

    [
      gauge(
        "shanghai_wal_current_lsn",
        "Next LSN the WAL will assign (log length).",
        Map.get(info, :current_lsn, 0)
      ),
      gauge(
        "shanghai_wal_active_segments",
        "Number of active WAL segments.",
        Map.get(info, :active_segments, 0)
      ),
      gauge(
        "shanghai_wal_entries",
        "Total entries across all WAL segments.",
        Map.get(wal, :entries, 0)
      ),
      gauge(
        "shanghai_wal_bytes",
        "Total on-disk size of all WAL segments in bytes.",
        Map.get(wal, :bytes, 0)
      ),
      gauge(
        "shanghai_storage_snapshots",
        "Number of persisted snapshots.",
        Map.get(info, :snapshots, 0)
      )
      | compaction_metrics()
    ]
  end

  defp compaction_metrics do
    stats = safe(fn -> Observability.MetricsReporter.get_compaction_stats() end, %{})

    [
      counter(
        "shanghai_compaction_runs_total",
        "Total compaction runs completed.",
        Map.get(stats, :count, 0)
      ),
      counter(
        "shanghai_compaction_bytes_reclaimed_total",
        "Total bytes reclaimed by compaction.",
        Map.get(stats, :bytes_reclaimed, 0)
      )
    ]
  end

  # --- Query metrics (per-operation count and total duration) ---

  defp query_metrics do
    ops = safe(fn -> Observability.MetricsReporter.get_query_stats() end, %{})

    count_header = [
      "# HELP shanghai_query_operations_total Query operations by type.\n",
      "# TYPE shanghai_query_operations_total counter\n"
    ]

    count_rows =
      Enum.map(ops, fn {operation, stat} ->
        count = Map.get(stat, :count, 0)
        ["shanghai_query_operations_total{operation=\"", to_string(operation), "\"} ", num(count), "\n"]
      end)

    duration_header = [
      "# HELP shanghai_query_operation_duration_ms Query operation duration in milliseconds.\n",
      "# TYPE shanghai_query_operation_duration_ms summary\n"
    ]

    duration_rows =
      Enum.map(ops, fn {operation, stat} ->
        op = to_string(operation)
        count = Map.get(stat, :count, 0)
        sum = Map.get(stat, :sum, 0)

        [
          "shanghai_query_operation_duration_ms_sum{operation=\"", op, "\"} ", num(sum), "\n",
          "shanghai_query_operation_duration_ms_count{operation=\"", op, "\"} ", num(count), "\n"
        ]
      end)

    error_header = [
      "# HELP shanghai_query_operation_errors_total Query operations that returned an error.\n",
      "# TYPE shanghai_query_operation_errors_total counter\n"
    ]

    error_rows =
      Enum.map(ops, fn {operation, stat} ->
        errors = Map.get(stat, :errors, 0)

        [
          "shanghai_query_operation_errors_total{operation=\"",
          to_string(operation),
          "\"} ",
          num(errors),
          "\n"
        ]
      end)

    [count_header, count_rows, duration_header, duration_rows, error_header | error_rows]
  end

  # --- Query read-cache metrics (from the live cache stats) ---

  defp cache_metrics do
    stats = safe(fn -> elem(Query.Cache.stats(), 1) end, %{})
    store = safe(fn -> elem(Query.info(), 1).store end, %{})

    [
      gauge(
        "shanghai_query_store_keys",
        "Number of keys in the materialized store.",
        Map.get(store, :size, 0)
      ),
      gauge(
        "shanghai_query_store_memory_bytes",
        "Approximate memory used by the store index in bytes.",
        Map.get(store, :memory_bytes, 0)
      ),
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

    extra = [
      gauge(
        "shanghai_replication_max_lag",
        "Maximum replica offset lag across all groups.",
        safe(fn -> Replication.max_lag() end, 0)
      ),
      gauge(
        "shanghai_replication_sync_ratio",
        "Fraction of tracked replicas fully caught up (0.0..1.0).",
        safe(fn -> Replication.sync_ratio() end, 1.0)
      )
    ]

    [header, rows | extra]
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

    quorum =
      safe(fn -> if Cluster.quorum_available?(), do: 1, else: 0 end, 0)

    health_ratio = safe(fn -> Cluster.health_ratio() end, 0.0)

    extra = [
      gauge(
        "shanghai_cluster_quorum_available",
        "Whether a majority of cluster nodes are up (1) or not (0).",
        quorum
      ),
      gauge(
        "shanghai_cluster_health_ratio",
        "Fraction of cluster nodes that are up (0.0..1.0).",
        health_ratio
      ),
      gauge(
        "shanghai_cluster_node_count",
        "Total number of nodes known to the cluster.",
        safe(fn -> Cluster.State.node_count(Cluster.cluster_state()) end, 0)
      ),
      gauge(
        "shanghai_cluster_fault_tolerance",
        "Number of node failures tolerable while retaining quorum.",
        safe(fn -> Cluster.fault_tolerance() end, 0)
      ),
      gauge(
        "shanghai_cluster_quorum_size",
        "Number of nodes required to form a quorum.",
        safe(fn -> Cluster.State.quorum_size(Cluster.cluster_state()) end, 0)
      )
    ]

    [header, rows | extra]
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
