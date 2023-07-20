# Changelog

All notable changes to Shanghai are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com/), and the project aims to
follow semantic versioning.

## [Unreleased]

### Added
- **Query layer** backed by the WAL: `Query.Store` (in-memory index +
  write-through + crash recovery by WAL replay), `Query.Cache` (read-through
  cache with TTL and bounded FIFO eviction), and the public API
  `read`/`write`/`delete`/`transact` plus `scan`/`keys`/`count`.
- **More Query primitives**: `take/1` (atomic pop), `update/3` (atomic
  read-modify-write), `increment/2` (atomic counter), `cas/3` (compare-and-swap),
  `mget/1` (multi-get), and `info/0` (store/cache introspection).
- **Conditional and bulk Query operations**: `put_new/2` (write-if-absent),
  `replace/2` (write-if-exists), `getset/2` (atomic get-and-set), `delete_prefix/1`
  (atomic range delete), `mset/1` / `mdelete/1` (atomic bulk write/delete), and
  the read helpers `exists?/1` and `count_prefix/1`. `read/2` and `write/3` also
  accept a string consistency level via a safe parse.
- **Query cache observability**: hit/miss counters and a `hit_ratio` in
  `Query.Cache.stats/0`, and the cache is tunable via
  `config :query, :cache, max_size:, ttl_ms:`.
- **Storage facade**: `Storage.read_range/2` and a `current_lsn` field in
  `Storage.info/0`.
- **Domain helpers**: `ConsistencyLevel.parse/1` (safe untrusted-input parsing),
  `LogEntry.newer_than?/2` / `older_than?/2`, `LogSequenceNumber.zero/0` /
  `advance/2`, and `NodeId.to_string/1`.
- **Cluster/replication introspection**: `Cluster.member?/1`, `Cluster.up_nodes/0`,
  and `Replication.summary/0` (group/replica/lag counts).
- **Admin API endpoints**: `GET /api/v1/kv/:key`, `GET /api/v1/nodes/:id`, a
  `store` section in `/api/v1/metrics`, a `summary` in `/api/v1/replicas`, and a
  broader `/ready` probe (query + storage). Prometheus now also exposes query
  cache metrics, WAL log length/segment gauges, and per-operation query duration.
- **CLI commands**: `shanghaictl kv get` and `shanghaictl node get`, plus a
  store/cache section in `shanghaictl metrics`.
- `Observability.Logger.ensure_correlation_id/0`, a get-or-create used by the
  Admin API correlation-id plug (which now honors a client-supplied header).
- **WAL batched-fsync foundation**: `Storage.WAL.Segment.append_entry_no_sync/2`
  and `sync/1`, letting a batch amortize one fsync over many writes.
- **Introspection helpers**: `Cluster.status/0` (node counts by status) and the
  `Admin.Health` aggregate subsystem health check.
- Configurable cluster (heartbeat/gossip) and `Replication.Monitor` options,
  resolved from application config.
- `CONTRIBUTING.md` with the development workflow, quality gates, and test
  conventions.
- **Query telemetry**: `[:shanghai, :query, :operation]` emitted for every
  operation with `duration_ms` and `{operation, result}`.
- **Admin API**: Prometheus text endpoint `GET /metrics` (WAL, replication lag,
  heartbeat RTT, cluster nodes), a `GET /ready` readiness probe distinct from
  `/health`, and a test suite for the HTTP surface.
- **Replication durability**: `Replication.Leader` persists each write and
  `Replication.Follower` applies each entry to the storage WAL when it is
  running (in-memory no-op otherwise).
- **CI**: an "English-only sources" check that fails on non-English text.
- Per-app README documentation for every umbrella app.

### Changed
- `Storage.Supervisor` now always starts the segment `Registry` and
  `SegmentManager` as base children.
- `Replication.Monitor` is started by the replication application (disabled
  under the test env via `config/test.exs`).
- `Storage.WAL.BatchWriter` now writes via `append_entry_no_sync/2` and issues a
  single `sync/1` per batch (real fsync amortization); a failed batch fsync is
  reported to all clients rather than silently succeeding.
- Extensive documentation reconciliation with the implementation: the WAL
  protocol spec (256-byte header, entry format including the LSN, LSNs from 0),
  storage config keys (`data_root`, not `data_dir`), Elixir/OTP version
  requirements, performance claims (targets vs. measured), deprecations,
  telemetry event names, and cross-referenced `ARCHITECTURE.md` files.

### Fixed
- Environment config is now imported relative to the config file rather than the
  current working directory, so it loads correctly from any app directory.
- `Observability.MetricsReporter` no longer crashes when a `NodeId` struct
  appears in a replication-lag/heartbeat key; event processing is also defensive
  so one malformed event can't take down the observability supervisor.
- `Storage.WAL.SegmentManager.stop_segment/1` waits for the registry entry to
  clear, removing a race; storage test suite stabilized (shared WAL infra now
  owned by the app, crash-safe teardowns, `start_supervised!` for WAL singletons).
- `Storage.Benchmark`: `wal_write_throughput/1` crashed on successful (`:ok`)
  results and divided by zero on sub-millisecond runs; `concurrent_writes/2` had
  the same division-by-zero bug.
