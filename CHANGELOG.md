# Changelog

All notable changes to Shanghai are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the version is `0.x`, the public API may change between releases.

Every entry describes what is actually implemented and verified, not what is
planned. Capability targets that are not yet met are called out as such.

## [Unreleased]

### Added

- **Startup fault-tolerance warning for replication groups.** A group's
  configured size fixes how many failures it can survive
  (`div(members - 1, 2)`), and the quorum math cannot be beaten - a two-member
  group tolerates zero. The coordinator now assesses this at startup and warns
  loudly when a group cannot fail over (one or two members) or is sized
  suboptimally (even count), so a false-safety configuration is visible rather
  than silent. Exposed as `Replication.GroupCoordinator.fault_tolerance/1`.

### Changed

- **`admin` is now a used library instead of a dead app.** It had a full,
  tested subsystem-health aggregate (`Admin.Health`) that nothing called and an
  empty supervisor. The empty `Admin.Application` is removed (it is now a
  library app), and `admin_api`'s `/ready` probe delegates to `Admin.Health`,
  so the HTTP layer and the health authority can no longer drift apart. The
  `/ready` JSON `checks` keys are now `cluster`/`storage`/`replication`/`query`.
- **`shanghaictl` builds as a standalone escript.** It is a client that talks
  to the Admin API over HTTP, so it does not belong inside the server release.
  `mix escript.build` in `apps/shanghaictl` produces the `shanghaictl` binary.
  Its spurious dependencies on the server apps (`cluster`, `replication`) are
  removed - they were booting a whole node just to run a CLI command.

## [0.2.0] - 2026-07-21

The theme of this release is making the distributed core safe and the
documentation honest. Several components that were documented as working turned
out to be dead code or stubs; they are now either implemented or accurately
described.

### Added

- **Quorum-gated, fenced leader failover.** Promotion now requires winning an
  election: a candidate takes the next leadership epoch, asks every configured
  member for a vote, and leads only with a strict majority. An unreachable
  member is a missing vote, so a partitioned minority cannot promote itself.
  Every replicated entry carries its leader's epoch, and a follower drops
  entries from a superseded epoch, so a deposed leader cannot keep writing.
  Votes are persisted (fsync) before they are granted, so a restart cannot
  undo one. This closes the split-brain window that previously existed.
- **Group commit in the WAL.** Concurrent appends now share a single fsync;
  each caller still blocks until its own entry is durable. Measured ~10.7x
  throughput at 100 concurrent writers versus one fsync per write.
- **Segment compaction now merges.** A selected group of rotated segments is
  merged into one, preserving every entry. (Previously the compactor logged
  success and did nothing.)
- **`mix test.disk`** runs the suite against a real filesystem instead of
  tmpfs, so durability tests exercise real fsync behaviour.
- **Catch-up telemetry** (`[:shanghai, :replication, :catchup]`) is now
  emitted, and compaction completion telemetry now has a real producer.
- **A reproducible WAL benchmark** (`apps/storage/bench/wal_bench.exs`).

### Fixed

- **`admin_api` is included in the release.** The assembled release previously
  shipped without the HTTP admin router or the Prometheus `/metrics` endpoint,
  despite both being documented.
- **Directory fsync actually works.** `FileBackend.sync_directory/1` opened
  directories in a mode that returns `:eisdir` on Linux, silently skipping the
  fsync; it now opens them correctly, restoring the durability guarantee of
  atomic writes.

### Changed

- **Performance numbers replaced with measured ones.** The invented benchmark
  tables (250,000 writes/sec, `<2 ms` P99) are replaced with measured figures:
  ~10,600 writes/sec peak and 3.16 ms P99 on an NVMe SSD. The original figures
  are documented as unmet targets; the throughput gap is the per-write fsync
  cost.
- **Architecture docs corrected.** Removed false claims that compaction
  reclaims space and that replication was "not yet networked", and documented
  the failover model's remaining limits honestly.

### Known limitations

- Replication leadership is **not Raft**: there is no log matching or commit
  index, so a newly elected leader is not guaranteed to hold every
  acknowledged entry. The offset-based completeness check narrows, but does not
  close, the window for lost writes.
- A replication group needs **at least three members** to fail over; a
  two-member group cannot form a majority after losing one member. A group
  configured without an explicit member list runs unfenced.
- Multi-master conflict resolution across independent writers is not
  implemented (manual reconciliation).
- Query-level routing and quorum, config hot-reload, and deployment tooling
  remain on the roadmap. The `admin` application is currently an empty
  supervisor; the live HTTP surface is `admin_api`.

## [0.1.0] - initial

The baseline before the 0.2.0 distributed-safety work.

- Durable Write-Ahead Log with segments, rotation, an index, snapshots, and
  crash recovery (single node).
- WAL-backed key/value store (`Query.Store`) with a read-through cache.
- Cluster membership, heartbeat failure detection, gossip, and seed-node
  discovery over Erlang distribution, with deterministic leader election.
- Replication `Leader`/`Follower`/`Stream`/`Monitor` with quorum acks; entry
  delivery, offset acks, and catch-up over Erlang distribution. Leader failover
  via `GroupCoordinator` was deterministic but **unfenced** - a partition could
  produce two writable leaders.
- Observability via telemetry and a Prometheus endpoint; an admin HTTP API and
  the `shanghaictl` CLI.

[Unreleased]: https://github.com/Tsunami43/shanghai/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Tsunami43/shanghai/releases/tag/v0.2.0
[0.1.0]: https://github.com/Tsunami43/shanghai/releases/tag/v0.1.0
