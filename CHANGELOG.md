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
- **Serialization views**: `to_map/1` for `LogEntry`, `Node`, and `Heartbeat`
  (plain-map forms with the LSN/node id rendered as integer/string), and
  `Cluster.State.topology/1` / `Cluster.topology/0` for a full cluster snapshot,
  surfaced over `GET /api/v1/topology`.
- **More value-object algebra**: `LogSequenceNumber` (`predecessor/1`,
  `contiguous?/2`), `ReplicationOffset` (`ahead?/2`, `caught_up?/2`, `delta/2`),
  `ConsistencyLevel` (`rank/1`, `compare/2` for the core levels; `all/0`,
  `equal?/2` for the replication levels), `NodeId.short/2`, and `LogEntry`
  (`lsn_value/1`, `get_metadata/3`, `put_metadata/3`).
- **Cluster/node introspection**: `Cluster.State` (`fault_tolerance/1`,
  `nodes_by_status/1`), `Cluster` facades (`fault_tolerance/0`, surfaced in
  `status/0`), `Node` (`never_seen?/1`, `stale?/2`), `Heartbeat`
  (`age_seconds/1`, `latest/2`, `has_metric?/2`, `get_metric/3`), and
  `NodeMetadata` (`capability_count/1`, `empty?/1`).
- **More Query/Cache operations**: `Query.to_map/0`, `to_list/0`, `missing/1`;
  `Query.Cache.cached?/1` (counter-free membership probe).
- **Query read ergonomics and collection operations**: `get/2`, `get_lazy/2`,
  `fetch!/1`; list ops `append/2`, `prepend/2`, `add_to_set/2`,
  `remove_from_list/2`, `list_member?/2`, `list_length/1`; map/hash ops
  `put_field/3`, `get_field/3`, `has_field?/2`, `delete_field/2`,
  `increment_field/3`, `decrement_field/3`.
- **Placement & ranges**: `NodeId.hash/1` / `slot/2` (consistent placement),
  `LogSequenceNumber.range/2`, `ReplicationOffset.range/2`, and `to_string/1`
  display forms for `LogSequenceNumber` and `ReplicationOffset`.
- **More cluster/storage/replication introspection**: `Cluster.State`
  (`get_node_by_address/2`, `local_node/1`, `nodes_by_status/1`),
  `Cluster.local_node/0`, `Node.last_seen_age_seconds/1`, `Storage.summary/0` /
  `total_entries/0` / `total_bytes/0` (over `GET /api/v1/storage`), and
  `Replication.group_ids/0` / `has_group?/1`. Prometheus now also exports
  cluster quorum, health-ratio, node-count, and fault-tolerance gauges.
- **Nested map operations**: `Query.get_path/3`, `put_path/3`, `delete_path/2`,
  `has_path?/2`; plus `pop_field/3`, `merge_fields/2`, `rename_field/3`,
  `field_count/1`, `fields/1`, and list `pop_first/1` / `pop_last/1`.
- **Serialization round-trips**: `from_map/1` for `LogEntry`, `Node`, and
  `Heartbeat` (inverses of `to_map/1`).
- **Value-object algebra**: `clamp/3` for `LogSequenceNumber` and
  `ReplicationOffset`, `LogSequenceNumber.diff/2`, `NodeId.sort/1`,
  `ConsistencyLevel.strongest/0` / `weakest/0` (core) and `rank/1` / `compare/2`
  / `stronger/2` / `weaker/2` (replication).
- **Topology & placement helpers**: `Cluster.State` (`stalest_node/1`,
  `freshest_node/1`, `node_hosts/1`, `nodes_on_host/2`), `Cluster.up_node_ids/0`,
  `Node.same_host?/2`, `Heartbeat.metric_names/1` / `metric_count/1`, and
  `NodeMetadata.tags/1` / `resources/1` / `with_version/2`.
- **Replication lag insight**: `Replication.max_lag/0` (also in `summary/0` and
  exported as the `shanghai_replication_max_lag` gauge), plus the
  `GET /api/v1/replicas/:group_id` endpoint.
- **Query scans & aggregates**: `filter/1`, `count_where/1`, `find/1`,
  `keys_where/1`, `map_values/1`, `reduce/2`, `sum_values/0`, `group_keys_by/1`,
  `values/0`, `pop_min/0` / `pop_max/0`, `bump_max/2` / `bump_min/2`,
  `update_path/3`, `warm/1`, `exists_all?/1` / `exists_any?/1`, and
  `summary/0`.
- **New CLI commands**: `shanghaictl storage`, `topology`, and `kv exists`, plus
  `Shanghaictl.Format` helpers (`yes_no/1`, `list/1`, `truncate/2`) now used to
  render durability flags and sizes.
- **Health & observability**: `Admin.Health.degraded?/0` and `summary/0`;
  `Observability` per-section stats accessors and `Metrics.events_for_domain/1`
  / `domains/0`. Replication also exposes `in_sync_count/0`, `sync_ratio/0`
  (gauge `shanghai_replication_sync_ratio`), and `group_ids/0`.
- **Value objects & placement**: `NodeMetadata.satisfies?/2` / `merge_all/1` /
  `with_version/2`, `LogSequenceNumber` (`gap/2`, `sort/1`, `sort_uniq/1`),
  `ReplicationOffset` (`distance/2`, `catch_up_ratio/2`, `sort/1`), `NodeId`
  (`uniq/1`, `contains?/2`), `Heartbeat` (`next/1`, `sequence_gap/2`),
  `LogEntry.same_node?/2` / `from_node?/2`, and `Node.same_address?/2`.
- **More cluster/storage introspection**: `Cluster.State` (`status_of/2`,
  `metadata_of/2`, `local?/2`, `peer_ids/1`, `majority?/2`, `count_on_host/2`,
  `duplicate_addresses?/1`), `Cluster.node_status/0` / `peer_ids/0`, and
  `Storage.segment_count/0` / `latest_segment_id/0`.
- **Aggregates & namespaces**: `Query` gains `avg_values/0`, `value_stats/0`,
  `max_value/0` / `min_value/0`, `namespaces/1`, `namespace_counts/1`,
  `map_prefix/1`, `drain_prefix/1`, `present/1`, `any?/0`, and `warm/1`.
- **`describe/1` log helpers** for `Cluster.State`, `Node`, `LogEntry`, and
  `Heartbeat`, plus `Node.with_status/2`, `current?/1`, and
  `NodeId.from_erlang_node/1`.
- **More value-object predicates**: `LogSequenceNumber` (`after?/2`, `before?/2`,
  `gap/2`), `ReplicationOffset.pending?/2`, `ConsistencyLevel`
  (`weaker_than?/2`, `at_least?/2`, `ordered/0`), `NodeId` (`ends_with?/2`,
  `length/1`), `NodeMetadata` (`tagged?/3`, `any_capabilities?/1`), and
  `LogEntry` metadata ops (`has_metadata?/2`, `metadata_keys/1`,
  `delete_metadata/2`, `merge_metadata/2`).
- **More topology/health/replication introspection**: `Cluster`
  (`unavailable_nodes/0`, `single_node?/0`), `Cluster.State`
  (`hosts_summary/1`, `address_of/2`, `has_address?/2`, `status_ratio/2`,
  `quorum_shortfall/1`, `single_node?/1`), `Replication`
  (`overview/0`, `fully_replicated?/0`), `Storage`
  (`oldest_segment_id/0`, `avg_entry_bytes/0`), and `Observability.Metrics`
  (`domains/0`, `domain_event_counts/0`).
- **Query iteration & predicates**: `each/1`, `map/1`, `all?/1`,
  `exists_pair?/1`, `partition/1`, `transform_values/1`, `distinct_values/0`,
  `max_by_value/0` / `min_by_value/0`, `count_existing/1`, and
  `unique_prefix?/1`.
- **Sequence/gap analysis**: `LogEntry.sort/1` / `contiguous?/1` / `from_node/2`,
  `LogSequenceNumber.increasing?/1` / `span/1` / `positive?/1`, and
  `ReplicationOffset.span/1` / `positive?/1` / `differ?/2`.
- **Symmetry & predicates**: `Cluster.State` (`all_up?/1`, `degraded?/1`,
  `available_nodes/1`, `node_ids_with_status/2`, `nodes_with_statuses/2`,
  `multi_host?/1`, `pending_event_count/1`, `peek_events/1`), `Cluster`
  (`degraded?/0`, `peers/0`, `up_count/0`, `quorum_shortfall/0`), `Node`
  (`available?/1`, `status_in?/2`, `seen?/1`), `NodeMetadata`
  (`resource_count/1`, `has_resource?/2`, `delete_resource/2`, `any_tags?/1`,
  `any_resources?/1`), `NodeId.differ?/2`, and `Replication`
  (`total_lag/0`, `behind_count/0`, `unhealthy_group_ids/0`).
- **CLI formatting**: `Shanghaictl.Format` (`pad/2`, `kv/3`, `dash/1`,
  `pluralize/3`, `yes_no/1`, `list/1`), `Storage.segment_span/0`, and
  `ConsistencyLevel` `ordered/0` (both) plus `strongest_of/1` / `weakest_of/1`.
- **Validating constructors**: `parse/1` for `NodeId`, `LogSequenceNumber`, and
  `ReplicationOffset` (`{:ok, _}` | `{:error, :invalid}`), plus `parse!/1` for
  both `ConsistencyLevel` modules.
- **More Query views**: `map/1`, `group_by/1`, `sort_by_value/1`,
  `pairs_with_value/1`, `keys_matching/1`, `value_counts/0`, `numeric_count/0`,
  `distinct_values/0`, `transform_values/1`, `only/0`, `single?/0`,
  `prefix_empty?/1`, and `unique_prefix?/1`.
- **Increment/decrement & extras**: `decrement/1` for `LogSequenceNumber` and
  `ReplicationOffset`, `LogEntry` (`max_by_lsn/1`, `min_by_lsn/1`,
  `in_lsn_range/3`, `node_ids/1`, `node_id_value/1`), `Heartbeat`
  (`older_than?/2`, `same_sequence?/2`, `without_metrics/1`), and `NodeMetadata`
  (`extra_capabilities/2`, `common_capabilities/2`, `same_version?/2`,
  `resource_or/3`).
- **More cluster/replication/storage introspection**: `Cluster.State`
  (`unavailable_ratio/1`, `addresses_with_status/2`, `available_node_ids/1`,
  `peer_count/1`, `host_count/1`, `multi_host?/1`, `multi_node?/1`,
  `clear_events/1`), `Node` (`on_port?/2`, `on_host?/2`, `at_address?/2`,
  `seen?/1`), `Replication` (`avg_lag/0`, `unhealthy_ratio/0`, `no_groups?/0`,
  `avg_replicas_per_group/0`, `any_unhealthy?/0`), and `Storage`
  (`no_segments?/0`, `has_snapshots?/0`, `snapshot_count/0`).
- **CLI formatting**: `Shanghaictl.Format.count_label/3`; and a fix for umbrella
  test flakiness (admin health tests derive expectations from live process
  state; the cache-TTL expiry test uses a wider TTL window).
- **Namespace-aware helpers**: `NodeId.namespace/2`, `Node.namespace/1` /
  `id_starts_with?/2`, `Cluster.State` (`namespaces/1`, `namespace_counts/1`,
  `nodes_with_id_prefix/2`), and `Query` (`namespaces/1`, `namespace_counts/1`,
  `keys_in_namespace/2`).
- **More Query predicates & views**: `all_keys?/1`, `all_values?/1`,
  `count_keys/1`, `count_values/1`, `has_value?/1`, `keys_for_value/1`,
  `find_key/1`, `first_key_where/1`, `partition_keys/1`, `slice/1`,
  `key_range/0`, `keys_desc/0`, `values_desc/0`, `to_entries/0`, `to_keyword/0`,
  `sum_of/1`, `single?/0`, `only/0`, `any?/0`, and `distinct_value_count/0`.
- **Value-object ranges & bisection**: `midpoint/2` and `rewind/2` for
  `LogSequenceNumber` and `ReplicationOffset`; `at_or_before?/2` /
  `at_or_after?/2` (both); `ReplicationOffset` (`sum/1`, `differ?/2`,
  `decrement/1`), `LogSequenceNumber` (`decrement/1`, `both_initial?/2`,
  `increasing?/1`, `span/1`); `ConsistencyLevel` (`parse!/1` both,
  `requires_coordination?/1`, `allows_stale_reads?/1`, `waits_for_peers?/1`,
  `durable?/1`); and `LogEntry` (`sort_desc/1`, `with_lsn/2`, `in_lsn_range/3`,
  `latest_of/1`, `earliest_of/1`, `group_by_node/1`, `node_ids/1`).
- **More cluster/replication/storage introspection**: `Cluster.State`
  (`quorum_lost?/1`, `any_nodes?/1`, `multi_node?/1`, `co_located?/1`,
  `any_with_status?/2`, `nodes_seen_within/2`, `unavailable_node_ids/1`,
  `peer_count/1`), `Cluster` (`quorum_lost?/0`, `node_count/0`, `down_count/0`,
  `suspect_count/0`, `up_count/0`), `Heartbeat` (`latest_of/1`, `earliest_of/1`,
  `within_age?/2`), `Replication` (`healthy_replica_count/0`,
  `unhealthy_group_count/0`, `healthy_group_ratio/0`, `any_lagging?/0`,
  `any_stale?/0`, `no_replicas?/0`, `group_replica_count/1`), and `Storage`
  (`fill_ratio/1`, `entries_until/1`).
- **Test stability**: fixed a real flaky in the `Node.mark_up/1` timestamp
  assertion (two `utc_now/0` calls could coincide) by pinning the prior
  timestamp and asserting the refresh advanced it.
- **Ordered/paged Query access**: `floor_entry/1`, `ceiling_entry/1`, `page/2`,
  `top_n/1`, `bottom_n/1`, `slice/1`, `find_key/1`, `first_key_where/1`,
  `numeric_pairs/0`, `pairs_with_value/1`, `has_exactly?/1`, `string_keys?/0`,
  `group_by_namespace/1`, `count_in_namespace/2`, and the atomic bulk ops
  `rekey/1` and `increment_namespace/3`.
- **Routing & availability**: `Node.fresh?/2` / `routable?/2`, `Cluster.State`
  (`routable_nodes/2`, `meets_availability?/2`, `count_seen_within/2`,
  `quorum_surplus/1`, `multi_namespace?/1`, `namespace_count/1`), and
  `Cluster.meets_availability?/1`.
- **Value-object clamps & stats**: `at_least/2` / `at_most/2` for
  `LogSequenceNumber` and `ReplicationOffset`; `ReplicationOffset.average/1`;
  `NodeMetadata` (`superset_of?/2`, `tag_values/3`); `Heartbeat`
  (`metric_as_float/3`, `earliest_of/1`); `LogEntry` (`ordered?/1`,
  `metadata_count/1`, `group_by_node/1`); `Node`
  (`id_starts_with?/2`, `namespace/1`); and `ConsistencyLevel`
  (`allows_stale_reads?/1`, `durable?/1`).
- **Replication insight**: `min_lag/0`, `healthy_replica_count/0`,
  `unhealthy_replicas/0`, `healthy_group_ratio/0`, and `no_replicas?/0`.
- **CLI formatting**: a `Shanghaictl.Format` module (`bytes/1`, `count/1`,
  `percent/1`, `duration_ms/1`) now used to render human-readable sizes and
  ratios in `shanghaictl metrics`; `Options.int_option/3`.
- **Storage**: `Storage.empty?/0`.
- **Storage/observability/CLI helpers**: `Storage.avg_segment_entries/0`;
  `Observability` (`Logger.with_new_correlation_id/1`,
  `Metrics.event_defined?/1`, `event_count/0`); `Admin.Health.healthy_subsystems/0`
  (with a `degraded` list in `GET /api/v1/health`); `Shanghaictl.Options`
  (`flag?/2`, `option/3`); `Replication` (`lagging_count/0`, `stale_count/0`).

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
