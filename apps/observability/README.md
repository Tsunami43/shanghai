# Observability

Telemetry, metrics aggregation and structured logging for Shanghai — the
"observable by default" backbone.

## Components

- **`Observability.Metrics`** — convenience emitters for the canonical
  `[:shanghai, ...]` telemetry events (WAL write/sync, replication lag/catchup,
  cluster heartbeat/membership, compaction, query operations).
- **`Observability.MetricsReporter`** — attaches to those events and keeps
  rolling statistics (`get_wal_stats/0`, `get_replication_stats/0`,
  `get_heartbeat_stats/0`). Event processing is defensive: one malformed event
  can never take the reporter (or the supervisor) down.
- **`Observability.Logger`** — structured logging with correlation-ID
  propagation.

Aggregated metrics are exposed as JSON and Prometheus text by the `admin_api` app.
