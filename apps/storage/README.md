# Storage

Durable local persistence for Shanghai: a segment-based Write-Ahead Log with
indexing, snapshots and compaction. This is the most complete subsystem.

## Components

- **WAL** — `Storage.WAL.Writer` (append, LSN assignment, size/time rotation,
  metadata) and `Storage.WAL.Reader` (random access by LSN, range scans).
- **Segments** — `Storage.WAL.Segment` (CRC32-checked append-only files),
  `Storage.WAL.SegmentManager` (DynamicSupervisor) and the
  `Storage.WAL.SegmentRegistry` — both started by `Storage.Supervisor`.
- **Index** — `Storage.Index.SegmentIndex` (ETS LSN→offset, persisted).
- **Snapshots** — point-in-time backups with compression and retention.
- **Compaction** — size-tiered strategy, compactor and scheduler.

The WAL write/sync hot path emits `[:shanghai, :storage, :wal, :write | :sync]`
telemetry at the point of the actual disk write.

## Configuration

The full stack starts when `config :storage, data_root: "/path"` is set;
otherwise a minimal set (registry, segment manager, compactor) runs.
