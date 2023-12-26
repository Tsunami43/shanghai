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
- **More Query operations**: `update_existing/2` (update-if-present),
  `get_or_store/2` (race-safe get-or-compute), `rename/2` (atomic key move), and
  `scan/2` with a `:limit` for pagination.
- **Cluster/storage introspection**: `Cluster.State.quorum_available?/1` and
  `Cluster.quorum_available?/0` (majority-up predicate, surfaced in status),
  `Cluster.member?/1`, `Cluster.up_nodes/0`, `Node.address/1`,
  `Storage.wal_stats/0`, `Storage.list_snapshots/0`, and
  `Storage.compaction_status/0`.
- **Cache/store visibility**: cache hit/miss counters, `hit_ratio` and `ttl_ms`
  in `Query.Cache.stats/0`, and `memory_bytes` in `Query.Store.info/0`.
- **Admin API endpoints**: `GET /api/v1` (endpoint catalog), `/api/v1/info`,
  `/api/v1/nodes/:id`, `/api/v1/snapshots`, `/api/v1/keys`, `/api/v1/kv`
  (key count), and a `store`/`storage` section plus `local_node_id` and
  `quorum_available` in the metrics/status payloads. A `RequestLogger` plug
  emits structured per-request logs.
- **CLI commands**: `shanghaictl health`, `info`, `kv count`, `kv keys`,
  `node get`, `--format json` for `status`/`health`/`info`, and richer
  `metrics`/`replicas` output.
- **Prometheus**: query cache/latency, WAL log length/segments/entries/bytes,
  snapshot count, and store key-count/memory gauges.
- **Even more Query operations**: `rename/2`, `copy/2`, `swap/2` (atomic key
  moves), `get_and_update/2` (Access-style), `delete_if/2` (conditional delete),
  and `decrement/2`. Bulk mutations batch cache invalidation via
  `Query.Cache.invalidate_many/1`.
- **Health predicates**: `Cluster.healthy?/0`, `Replication.healthy?/0`,
  `Admin.healthy?/0`, `Cluster.State.quorum_size/1`, and a `healthy` flag in the
  replication summary.
- **Admin API**: `GET /api/v1/health` (semantic subsystem health),
  `/api/v1/config` (effective config), `/api/v1/keys` (prefix listing),
  `POST /api/v1/snapshots` and `POST /api/v1/compaction` (maintenance triggers),
  a `GET /api/v1` endpoint catalog, and JSON 404s.
- **CLI**: `config`, `snapshot list|create`, `compact`, `kv keys` commands;
  `SHANGHAI_ADMIN_URL` env-var resolution; query error counts in `metrics`.
- **Observability**: per-operation query error counts, compaction-run
  aggregation, `MetricsReporter.reset/0`, and typespecs plus emitter smoke tests
  for `Observability.Metrics`.
- **Storage**: `append!/1`, `wal_stats/0`, `list_snapshots/0`,
  `compaction_status/0`, `create_snapshot/0`, and `trigger_compaction/0`.
- **Value-object algebra**: ordering/utility helpers across the domain —
  `LogSequenceNumber` (`later/2`, `earlier/2`, `to_integer/1`, `distance/2`,
  `between?/3`, `min_of/1`, `max_of/1`, `initial?/1`), `ReplicationOffset`
  (`to_integer/1`, `equal?/2`, `later/2`, `earlier/2`, `between?/3`, `min_of/1`,
  `max_of/1`, `initial?/1`), `LogEntry` (`same_lsn?/2`, `latest/2`, `earliest/2`,
  `metadata_empty?/1`), `NodeId` (`valid?/1`, `compare/2`, `starts_with?/2`),
  and `ConsistencyLevel` (`parse/1`, `stronger/2`, `weaker/2`).
- **Cluster/query introspection**: `Cluster.State` (`quorum_size/1`,
  `health_ratio/1`, `status_summary/1`, `empty?/1`, `node_ids/1`,
  `node_addresses/1`), `Cluster` facades (`health_ratio/0`, `node_ids/0`,
  `node_addresses/0`, `down_nodes/0`, `suspect_nodes/0`), `Node`
  (`unavailable?/1`, `last_seen_age_ms/1`), `Heartbeat` (`newer_than?/2`,
  `stale?/2`), `NodeMetadata` (`capabilities/1`, `has_all_capabilities?/2`,
  `has_any_capability?/2`, `remove_capability/2`, tag/resource helpers,
  `merge/2`), and `Storage` (`durable?/0`, `avg_segment_bytes/0`,
  `segment_ids/0`).
- **More Query operations**: `clear/0` (durable, WAL `:clear` record),
  `empty?/0`, `min_key/0`, `max_key/0`, `any_prefix?/1`, `keys_prefix/1`,
  `values_prefix/1`; `Query.Cache.size/0`/`invalidate_many/1`;
  `Observability` (`clear_correlation_id/0`, `correlation_id/0`,
  `MetricsReporter.reset/0`); `Admin` (`unhealthy_subsystems/0`,
  `Health.health_ratio/1`); `Replication` (`replica_count/0`, `group_count/0`,
  `healthy?/0`).

### Fixed (this cycle)
- `Query.delete_prefix/1` scanned the default store table instead of the target
  instance's table, breaking it for non-default `Query.Store` instances.
- `Query.decrement/2` emitted an `:increment` telemetry op instead of
  `:decrement`.
- `/health` now sets the `application/json` content-type; unknown routes return
  a JSON 404. The WAL `Storage.WAL.Writer.append!/1` referenced by the docs is
  now implemented.
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
