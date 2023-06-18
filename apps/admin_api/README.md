# AdminApi

HTTP/JSON administration API for Shanghai, served with Plug/Cowboy
(default port `9090`).

## Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness probe (`{"status":"ok"}`) |
| GET | `/ready` | Readiness probe (200/503 with per-process checks) |
| GET | `/metrics` | Prometheus text exposition (0.0.4) |
| GET | `/api/v1/status` | Cluster health summary |
| GET | `/api/v1/nodes` | Cluster members |
| POST | `/api/v1/nodes` | Join/leave a node |
| GET | `/api/v1/replicas` | Replication groups and follower lag |
| GET | `/api/v1/metrics` | Aggregated metrics as JSON |
| POST | `/api/v1/shutdown` | Graceful or forced shutdown |

Every request carries an `X-Correlation-ID` (generated when absent) for tracing.

## Prometheus

`AdminApi.Prometheus.render/0` renders WAL, replication-lag and cluster-node
metrics from `Observability.MetricsReporter` and the live cluster state.
Scrape `GET /metrics`.
