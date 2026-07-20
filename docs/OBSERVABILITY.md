# Shanghai Observability and Monitoring Guide

This guide covers observability, monitoring, and debugging for Shanghai in production environments.

## Table of Contents

- [Overview](#overview)
- [Telemetry Architecture](#telemetry-architecture)
- [Key Metrics](#key-metrics)
- [Prometheus Integration](#prometheus-integration)
- [Grafana Dashboards](#grafana-dashboards)
- [Alerting](#alerting)
- [Logging](#logging)
- [Distributed Tracing](#distributed-tracing)
- [Debugging Tools](#debugging-tools)

## Overview

Shanghai provides comprehensive observability through:

- **Telemetry events**: Real-time metrics via `:telemetry` library
- **Structured logging**: Contextual logs with correlation IDs
- **Admin API**: HTTP endpoints for metrics and status
- **BEAM introspection**: Access to Erlang VM metrics

### Observability Stack

```
┌─────────────────────────────────────────────────────┐
│                Shanghai Application                 │
│                                                     │
│  ┌──────────────┐                                  │
│  │  :telemetry  │ (events)                         │
│  └──────┬───────┘                                  │
│         │                                           │
│         ├──────> Prometheus Reporter                │
│         ├──────> Logger Handler                     │
│         └──────> Custom Handlers                    │
│                                                     │
└─────────────────────────────────────────────────────┘
           │                    │
           ▼                    ▼
    ┌─────────────┐      ┌─────────────┐
    │ Prometheus  │      │   Loki/ELK  │
    └─────┬───────┘      └─────────────┘
          │
          ▼
    ┌─────────────┐
    │   Grafana   │
    └─────────────┘
```

## Telemetry Architecture

### Event Namespace

All Shanghai events follow the pattern:

```
[:shanghai, <subsystem>, <component>, <event>]
```

Event names have three or four segments. The canonical list is
`Observability.Metrics.event_names/0`.

**Examples:**
- `[:shanghai, :storage, :wal, :write]`
- `[:shanghai, :cluster, :heartbeat]`
- `[:shanghai, :query, :operation]`

### Event Structure

Each event includes:

1. **Measurements**: Numeric metrics (duration, bytes, count)
2. **Metadata**: Contextual information (node_id, segment_id)

**Example:**

```elixir
:telemetry.execute(
  [:shanghai, :storage, :wal, :write],
  %{duration: 3.2, bytes: 1024},  # Measurements
  %{segment_id: 1}                # Metadata
)
```

### Available Events

The canonical list of event names is `Observability.Metrics.event_names/0`.
Events marked *(defined, not yet emitted)* have an `Observability.Metrics`
helper but no producer wired up yet.

#### Storage Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:shanghai, :storage, :wal, :write]` | `duration`, `bytes` | `segment_id` |
| `[:shanghai, :storage, :wal, :sync]` | `duration` | `segment_id` |
| `[:shanghai, :storage, :compaction, :complete]` *(defined, not yet emitted)* | `duration_ms`, `bytes_before`, `bytes_after` | `segment_ids` |

#### Cluster Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:shanghai, :cluster, :heartbeat]` | `rtt_ms` | `source_node`, `target_node` |
| `[:shanghai, :cluster, :membership_change]` | `node_count` | `event_type`, `node_id` |

#### Replication Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:shanghai, :replication, :lag]` | `offset_lag`, `time_lag_ms` | `group_id`, `follower_id`, `leader_id` |
| `[:shanghai, :replication, :catchup]` | `duration_ms`, `records_replicated` | `group_id`, `follower_id` |

#### Query Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:shanghai, :query, :operation]` | `duration_ms` | `operation`, `result` |

## Key Metrics

### Storage Metrics

#### WAL Write Duration

**What:** Time to write entry to WAL

**Type:** Histogram

**Unit:** Milliseconds

**Why:** Detect slow disk I/O, optimize batching

**Alert thresholds:**
- Warning: P99 > 10ms
- Critical: P99 > 50ms

**Example query (PromQL):**
```promql
# Average WAL write duration (exposed as a summary, not a histogram)
rate(shanghai_wal_write_duration_ms_sum[5m])
  / rate(shanghai_wal_write_duration_ms_count[5m])
```

#### WAL Write Throughput

**What:** Entries written per second

**Type:** Counter (rate)

**Unit:** writes/sec

**Why:** Track write load, capacity planning

**Alert thresholds:**
- Warning: < 1000 writes/sec (underutilized)
- Critical: Sustained > 50,000 writes/sec (near capacity)

**Example query:**
```promql
rate(shanghai_wal_writes_total[1m])
```

### Cluster Metrics

#### Node Count

**What:** Number of nodes in cluster

**Type:** Gauge

**Unit:** Count

**Why:** Detect node failures, capacity

**Alert thresholds:**
- Critical: < 3 nodes (under-replicated)

**Example query:**
```promql
# Nodes currently up (also available: status="down" / "suspect")
shanghai_cluster_nodes{status="up"}
```

#### Heartbeat RTT

**What:** Round-trip time for heartbeats

**Type:** Histogram

**Unit:** Milliseconds

**Why:** Detect network issues

**Alert thresholds:**
- Warning: P99 > 50ms
- Critical: P99 > 200ms

**Example query:**
```promql
# Average heartbeat RTT per link (exposed as a gauge, not a histogram)
shanghai_cluster_heartbeat_rtt
```

### Replication Metrics

#### Replication Lag

**What:** Offset difference between leader and follower

**Type:** Gauge

**Unit:** Offsets

**Why:** Detect slow followers, data loss risk

**Alert thresholds:**
- Warning: > 10,000 offsets
- Critical: > 100,000 offsets

**Example query:**
```promql
shanghai_replication_lag
```

#### Credit Balance

**What:** Available flow control credits

**Type:** Gauge

**Unit:** Credits

**Why:** Detect backpressure

**Alert thresholds:**
- Warning: < 10 credits (backpressure)

**Example query:**
```promql
# Not yet exposed by the Prometheus endpoint (credit tracking is on the roadmap).
shanghai_replication_credit
```

## Prometheus Integration

Shanghai serves Prometheus metrics from the **Admin API**: scrape
`GET /metrics` on the admin_api port (default `9090`). The body is Prometheus
text exposition format, rendered by `AdminApi.Prometheus` from
`Observability.MetricsReporter` aggregates plus live cluster state.

**Metrics exposed today:**

| Metric | Type | Labels |
|---|---|---|
| `shanghai_wal_writes_total` | counter | — |
| `shanghai_wal_write_duration_ms` | summary | — |
| `shanghai_wal_sync_duration_ms` | summary | — |
| `shanghai_wal_current_lsn` | gauge | — |
| `shanghai_wal_active_segments` | gauge | — |
| `shanghai_wal_entries` | gauge | — |
| `shanghai_wal_bytes` | gauge | — |
| `shanghai_storage_snapshots` | gauge | — |
| `shanghai_compaction_runs_total` | counter | — |
| `shanghai_compaction_bytes_reclaimed_total` | counter | — |

> Both compaction counters stay at `0`: the compactor does not merge segments
> yet, so it never emits `[:shanghai, :storage, :compaction, :complete]`.
| `shanghai_query_operations_total` | counter | `operation` |
| `shanghai_query_operation_duration_ms` | summary | `operation` |
| `shanghai_query_operation_errors_total` | counter | `operation` |
| `shanghai_query_store_keys` | gauge | — |
| `shanghai_query_store_memory_bytes` | gauge | — |
| `shanghai_query_cache_size` | gauge | — |
| `shanghai_query_cache_hit_ratio` | gauge | — |
| `shanghai_query_cache_hits_total` | counter | — |
| `shanghai_query_cache_misses_total` | counter | — |
| `shanghai_replication_lag` | gauge | `follower` |
| `shanghai_cluster_heartbeat_rtt` | gauge | `link` |
| `shanghai_cluster_nodes` | gauge | `status` |

> The `telemetry_metrics_prometheus`-based setup below (a dedicated exporter on
> port 9568) is an **alternative future design**, not the current integration.

### Setup (alternative future design)

1. **Add dependency** (`mix.exs`):

```elixir
defp deps do
  [
    {:telemetry_metrics_prometheus, "~> 1.1"}
  ]
end
```

2. **Configure reporter** (`config/prod.exs`):

```elixir
config :shanghai, Observability.PrometheusReporter,
  port: 9568,
  metrics: Observability.Metrics.definitions()
```

3. **Start reporter** (application.ex):

```elixir
children = [
  # ... other children ...
  {Observability.PrometheusReporter, []}
]
```

### Metric Definitions

Create `lib/observability/metrics.ex`:

```elixir
defmodule Observability.Metrics do
  use TelemetryMetricsPrometheus

  def definitions do
    [
      # Storage metrics
      histogram("shanghai.wal.write.duration",
        unit: {:native, :millisecond},
        buckets: [1, 2, 5, 10, 25, 50, 100],
        tags: [:segment_id]
      ),

      counter("shanghai.wal.writes.total",
        tags: [:segment_id]
      ),

      # Cluster metrics
      gauge("shanghai.cluster.nodes.total",
        tags: [:status]
      ),

      histogram("shanghai.cluster.heartbeat.rtt",
        unit: {:native, :millisecond},
        buckets: [1, 5, 10, 25, 50, 100, 200],
        tags: [:from_node, :to_node]
      ),

      # Replication metrics
      gauge("shanghai.replication.lag",
        tags: [:follower, :leader]
      ),

      gauge("shanghai.replication.credit",
        tags: [:follower]
      )
    ]
  end
end
```

### Scrape Configuration

Add to Prometheus config (`prometheus.yml`), pointing at the admin_api port:

```yaml
scrape_configs:
  - job_name: 'shanghai'
    metrics_path: /metrics
    static_configs:
      - targets:
          - 'node1:9090'
          - 'node2:9090'
          - 'node3:9090'
    scrape_interval: 15s
```

## Grafana Dashboards

### Main Dashboard

Create dashboard with panels:

#### Panel 1: WAL Write Performance

**Metric:** WAL write P99 latency

**Query:**
```promql
# Average WAL write duration (exposed as a summary, not a histogram)
rate(shanghai_wal_write_duration_ms_sum[5m])
  / rate(shanghai_wal_write_duration_ms_count[5m])
```

**Visualization:** Time series graph

**Alert:** > 10ms (warning), > 50ms (critical)

---

#### Panel 2: Cluster Health

**Metric:** Node status breakdown

**Query:**
```promql
sum by (status) (shanghai_cluster_nodes)
```

**Visualization:** Stat panel

**Alert:** down > 0

---

#### Panel 3: Replication Lag

**Metric:** Max lag across all followers

**Query:**
```promql
max(shanghai_replication_lag)
```

**Visualization:** Time series

**Alert:** > 10,000 offsets

---

#### Panel 4: Throughput

**Metric:** Writes per second

**Query:**
```promql
sum(rate(shanghai_wal_writes_total[1m]))
```

**Visualization:** Time series

---

### Dashboard JSON

Save as `grafana/shanghai-dashboard.json`:

```json
{
  "dashboard": {
    "title": "Shanghai Overview",
    "panels": [
      {
        "id": 1,
        "title": "WAL Write Avg Latency",
        "targets": [
          {
            "expr": "rate(shanghai_wal_write_duration_ms_sum[5m]) / rate(shanghai_wal_write_duration_ms_count[5m])"
          }
        ],
        "type": "graph"
      },
      {
        "id": 2,
        "title": "Cluster Nodes",
        "targets": [
          {
            "expr": "sum by (status) (shanghai_cluster_nodes)"
          }
        ],
        "type": "stat"
      }
    ]
  }
}
```

## Alerting

### Alertmanager Rules

Create `alerts/shanghai.yml`:

```yaml
groups:
  - name: shanghai
    interval: 30s
    rules:
      # Storage alerts
      - alert: HighWALWriteLatency
        expr: |
          rate(shanghai_wal_write_duration_ms_sum[5m])
            / rate(shanghai_wal_write_duration_ms_count[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High WAL write latency"
          description: "P99 write latency is {{ $value }}ms"

      - alert: DiskFull
        expr: |
          shanghai_disk_usage_percent > 85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk nearly full"
          description: "Disk usage at {{ $value }}%"

      # Cluster alerts
      - alert: NodeDown
        expr: |
          shanghai_cluster_nodes{status="down"} > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Cluster node down"
          description: "{{ $value }} nodes are down"

      - alert: ClusterUnderReplicated
        expr: |
          shanghai_cluster_nodes{status="up"} < 3
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Cluster under-replicated"
          description: "Only {{ $value }} nodes available"

      # Replication alerts
      - alert: HighReplicationLag
        expr: |
          shanghai_replication_lag > 10000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High replication lag"
          description: "Lag is {{ $value }} offsets"

      - alert: ReplicationCreditExhausted
        expr: |
          shanghai_replication_credit < 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Replication backpressure"
          description: "Only {{ $value }} credits remaining"
```

### Notification Channels

Configure Alertmanager (`alertmanager.yml`):

```yaml
route:
  group_by: ['alertname', 'cluster']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'slack'

receivers:
  - name: 'slack'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/XXX'
        channel: '#shanghai-alerts'
        title: 'Shanghai Alert'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'
```

## Logging

### Structured Logging

Shanghai uses structured logging with correlation IDs:

```elixir
defmodule Observability.Logger do
  require Logger

  def info(message, metadata \\\\ []) do
    Logger.info(message, metadata ++ common_metadata())
  end

  def warning(message, metadata \\\\ []) do
    Logger.warning(message, metadata ++ common_metadata())
  end

  def error(message, metadata \\\\ []) do
    Logger.error(message, metadata ++ common_metadata())
  end

  defp common_metadata do
    [
      node_id: Cluster.Membership.local_node_id().value,
      pid: inspect(self()),
      correlation_id: Process.get(:correlation_id)
    ]
  end
end
```

### Log Aggregation

#### Loki Configuration

`loki/config.yml`:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1

schema_config:
  configs:
    - from: 2025-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
```

#### Promtail Configuration

`promtail/config.yml`:

```yaml
server:
  http_listen_port: 9080

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: shanghai
    static_configs:
      - targets:
          - localhost
        labels:
          job: shanghai
          __path__: /var/log/shanghai/*.log
```

### Log Queries

**Find errors in last hour:**
```logql
{job="shanghai"} |= "error" | json | level="error"
```

**WAL write failures:**
```logql
{job="shanghai"} | json | message="WAL write failed"
```

**High latency writes:**
```logql
{job="shanghai"} | json | duration_ms > 10
```

## Distributed Tracing

### OpenTelemetry Integration

**Add dependency:**

```elixir
{:opentelemetry, "~> 1.0"},
{:opentelemetry_exporter, "~> 1.0"},
{:opentelemetry_api, "~> 1.0"}
```

**Configure:**

```elixir
config :opentelemetry, :processors,
  otel_batch_processor: %{
    exporter: {:otel_exporter_stdout, []}
  }
```

**Instrument code:**

```elixir
defmodule Storage.WAL.Writer do
  require OpenTelemetry.Tracer, as: Tracer

  def append(data) do
    Tracer.with_span "wal.write" do
      Tracer.set_attributes([
        {"wal.bytes", byte_size(data)},
        {"wal.segment", segment_id()}
      ])

      # ... write logic ...

      Tracer.set_attribute("wal.lsn", lsn)
      {:ok, lsn}
    end
  end
end
```

## Debugging Tools

### BEAM Introspection

#### Observer

Connect to running node and start Observer:

```bash
iex --name debug@127.0.0.1 --cookie shanghai --remsh node1@127.0.0.1
```

```elixir
iex> :observer.start()
```

#### Process Info

```elixir
# Find process by name
iex> pid = Process.whereis(Storage.WAL.Writer)
iex> Process.info(pid)

# Check message queue
iex> {:message_queue_len, len} = Process.info(pid, :message_queue_len)
iex> if len > 100, do: IO.puts("Queue backlog!")

# Memory usage
iex> {:memory, bytes} = Process.info(pid, :memory)
iex> IO.puts("Memory: #{bytes / 1024 / 1024} MB")
```

#### Recon

```elixir
# Top memory consumers
iex> :recon.proc_count(:memory, 10)

# Top processes by reductions (CPU)
iex> :recon.proc_count(:reductions, 10)

# Find bottlenecks
iex> :recon.proc_window(:memory, 10, 5000)
```

### Admin API Debugging

**Check cluster status:**

```bash
curl http://localhost:9090/api/v1/status | jq
```

**Check replication lag:**

```bash
curl http://localhost:9090/api/v1/replicas | jq '.replicas[] | select(.lag > 1000)'
```

## Best Practices

### 1. Monitor What Matters

Focus on:
- **User-facing metrics**: Latency, throughput, errors
- **Resource utilization**: CPU, memory, disk, network
- **Business metrics**: Writes/sec, replication lag

Avoid:
- Vanity metrics that don't drive action
- Over-alerting on transient issues

### 2. Alert on Symptoms, Not Causes

**Good:**
- "Replication lag > 10,000 offsets"
- "P99 latency > 50ms"

**Bad:**
- "Disk I/O wait > 5%"
- "GC pause > 100ms"

### 3. Set Meaningful Thresholds

Use percentiles, not averages:
- P50: Typical performance
- P95: Degraded but acceptable
- P99: Alert threshold

### 4. Test Your Alerts

```bash
# Trigger test alert
curl -X POST http://localhost:9093/api/v1/alerts \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"}}]'
```

### 5. Document Runbooks

For each alert, document:
- What it means
- How to investigate
- How to remediate

## See Also

- [Operations Guide](OPERATIONS.md)
- [Performance Tuning](TUNING.md)
- [Architecture](ARCHITECTURE.md)
- [Admin API Reference](API.md#admin-api)
