# Admin

Cross-cutting administration app for Shanghai. It sits above the other bounded
contexts (it depends on `core_domain`, `storage`, `cluster`, `replication` and
`query`) and is the intended home for operational concerns that observe or
coordinate the whole system.

## Health

`Admin.health/0` (see `Admin.Health`) returns an aggregate health report across
subsystems, a per-subsystem liveness map (`storage`, `cluster`, `replication`,
`query`) and an overall `:healthy`/`:degraded` status.

## Status

Other operational surfaces are provided today by:

- **`admin_api`**: HTTP/JSON admin API and the Prometheus `/metrics` endpoint.
- **`shanghaictl`**: command-line control tool.
- **`observability`**: telemetry metrics, structured logging, aggregation.

Planned here: dynamic config management with hot reload, aggregate health
checking, and a monitoring dashboard.
