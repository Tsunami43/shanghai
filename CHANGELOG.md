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
