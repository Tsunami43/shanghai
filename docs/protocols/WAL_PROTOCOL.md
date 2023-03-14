# WAL Protocol Specification

**Version:** 1.0
**Status:** Stable
**Last Updated:** 2025-09-28

This document specifies the Write-Ahead Log (WAL) format, semantics, and on-disk layout used by Shanghai.

## Table of Contents

- [Overview](#overview)
- [Design Goals](#design-goals)
- [Terminology](#terminology)
- [File Format](#file-format)
- [Entry Format](#entry-format)
- [Segment Management](#segment-management)
- [Crash Recovery](#crash-recovery)
- [Compaction](#compaction)
- [Implementation Notes](#implementation-notes)

## Overview

The Shanghai WAL is an **append-only log** that provides:

- **Durability**: All writes are fsync'd to disk
- **Ordering**: Monotonically increasing Log Sequence Numbers (LSNs)
- **Integrity**: CRC32 checksums for corruption detection
- **Efficiency**: Sequential writes with optional batching

The WAL is the **source of truth** for all data in Shanghai. Replication, recovery, and compaction all work from the WAL.

## Design Goals

1. **Crash safety**: Survive power loss, kernel panic, process kill
2. **Performance**: Sequential I/O, minimal seeks
3. **Simplicity**: Easy to implement, debug, and verify
4. **Compatibility**: Forward/backward compatible across versions

### Non-Goals

- **Random access**: WAL is append-only, no updates/deletes
- **Compression**: Keep format simple (compression in future version)
- **Encryption**: Handled at filesystem/disk level

## Terminology

| Term | Definition |
|------|------------|
| **WAL** | Write-Ahead Log, the entire log |
| **Segment** | A single WAL file (e.g., `segment_00001.wal`) |
| **Entry** | A single log record with user data |
| **LSN** | Log Sequence Number, globally unique offset |
| **Offset** | Synonym for LSN |
| **Batch** | Multiple entries fsync'd together |

## File Format

### Directory Structure

```
/var/lib/shanghai/data/
├── segment_00001.wal      # Active segment
├── segment_00002.wal      # Older segment
├── segment_00003.wal      # Oldest segment
└── metadata.json          # Segment metadata (optional)
```

### Naming Convention

Segments are named sequentially:

```
segment_00001.wal
segment_00002.wal
segment_00003.wal
...
segment_99999.wal
```

**Format:** `segment_NNNNN.wal` where `NNNNN` is zero-padded 5-digit decimal.

### Segment Lifecycle

```
┌─────────┐
│ Created │ (new segment file)
└────┬────┘
     │
     ▼
┌─────────┐
│ Active  │ (receiving writes)
└────┬────┘
     │ (reaches threshold size)
     ▼
┌─────────┐
│ Sealed  │ (read-only, immutable)
└────┬────┘
     │ (compaction)
     ▼
┌─────────┐
│ Deleted │
└─────────┘
```

## File Format Specification

### Segment Structure

A segment file consists of:

1. **Header** (64 bytes, fixed size)
2. **Entries** (variable size, appended sequentially)

```
┌────────────────────────────────────────┐
│  Segment Header (64 bytes)             │  Offset 0
├────────────────────────────────────────┤
│  Entry 1 (variable)                    │  Offset 64
├────────────────────────────────────────┤
│  Entry 2 (variable)                    │  Offset 64 + size(Entry 1)
├────────────────────────────────────────┤
│  Entry 3 (variable)                    │
├────────────────────────────────────────┤
│  ...                                   │
└────────────────────────────────────────┘
```

### Segment Header (64 bytes)

| Offset | Size | Type | Name | Description |
|--------|------|------|------|-------------|
| 0 | 6 | bytes | Magic | `0x5348414E4741` ("SHANGA" in ASCII) |
| 6 | 2 | uint16 | Version | Format version (current: 1) |
| 8 | 16 | UUID | Segment ID | Unique segment identifier |
| 24 | 8 | uint64 | Created | Unix timestamp (milliseconds) |
| 32 | 8 | uint64 | First LSN | First LSN in this segment |
| 40 | 8 | uint64 | Last LSN | Last LSN in this segment (0 if active) |
| 48 | 16 | bytes | Reserved | Reserved for future use (zeros) |

**Example (hexdump):**

```
00000000  53 48 41 4e 47 41 00 01  f4 7a c5 72 e3 4d 4a b3  |SHANGA...z.r.MJ.|
00000010  9c 8e 3f 2a 1b 6f c8 4e  00 00 01 8b 2e 5f a0 00  |..?*.o.N....._.|
00000020  00 00 00 00 00 00 00 01  00 00 00 00 00 00 00 00  |................|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
```

### Entry Format

Each entry consists of:

1. **Length** (4 bytes): Size of data payload
2. **CRC32** (4 bytes): Checksum of data
3. **Data** (variable): User payload

| Offset | Size | Type | Name | Description |
|--------|------|------|------|-------------|
| 0 | 4 | uint32 | Length | Byte count of data field |
| 4 | 4 | uint32 | CRC32 | CRC32 checksum of data |
| 8 | Length | bytes | Data | User payload |

**Total entry size:** `8 + Length` bytes

**Example:**

```
# Entry with data "Hello, Shanghai!" (16 bytes)

Length:  0x00000010  (16 in decimal)
CRC32:   0xA3B2C1D0  (example checksum)
Data:    "Hello, Shanghai!"

┌─────────────┬─────────────┬──────────────────────┐
│  00 00 00 10│  A3 B2 C1 D0│  48 65 6c 6c 6f ...  │
│  (Length)   │  (CRC32)    │  (Data)              │
└─────────────┴─────────────┴──────────────────────┘
```

### CRC32 Calculation

Shanghai uses the **CRC-32/ISO-HDLC** polynomial:

- **Polynomial:** `0x04C11DB7`
- **Initial value:** `0xFFFFFFFF`
- **Final XOR:** `0xFFFFFFFF`
- **Reflect input:** Yes
- **Reflect output:** Yes

**Erlang implementation:**

```elixir
def calculate_crc32(data) do
  :erlang.crc32(data)
end
```

### LSN Assignment

LSNs are assigned **sequentially** starting from 1:

```
Segment 1:
  Entry 1: LSN = 1
  Entry 2: LSN = 2
  Entry 3: LSN = 3

Segment 2:
  Entry 4: LSN = 4
  Entry 5: LSN = 5
  ...
```

**LSN 0 is reserved** and means "no LSN" or "beginning of log."

## Segment Management

### Segment Rotation

A new segment is created when:

- **Size threshold reached**: Current segment ≥ 64 MB (configurable)
- **Manual rotation**: Operator triggers rotation
- **Time-based**: After N hours (future feature)

**Rotation algorithm:**

```
1. Current segment reaches threshold
2. Seal current segment (mark Last LSN in header)
3. Create new segment with incremented ID
4. Update First LSN = Last LSN + 1
5. Atomically switch active segment
```

### Atomic Segment Switch

```elixir
# Pseudocode
def rotate_segment(current_segment) do
  # 1. Fsync current segment
  :file.sync(current_segment.handle)

  # 2. Update header with Last LSN
  update_header(current_segment, last_lsn: current_lsn())

  # 3. Create new segment
  new_segment = create_segment(
    segment_id: current_segment.id + 1,
    first_lsn: current_lsn() + 1
  )

  # 4. Atomically switch (GenServer state update)
  {:ok, new_segment}
end
```

### Segment Compaction

Old segments can be **compacted** (deleted) when:

- All replicas have acknowledged entries
- Retention period expired
- Manual compaction triggered

**Safety:** Never delete segments still being replicated.

## Crash Recovery

### Recovery Procedure

On startup, Shanghai performs WAL recovery:

```
1. Scan segment directory
2. Open each segment, verify header
3. For each entry:
   a. Read length + CRC32 + data
   b. Verify CRC32 matches data
   c. If valid: increment LSN counter
   d. If invalid: truncate file at this point
4. Resume from last valid LSN
```

### Torn Write Detection

A **torn write** occurs when a crash happens mid-write:

```
Entry N:
  Length:  0x00000100 ✓
  CRC32:   0xA3B2C1D0 ✓
  Data:    [corrupted, only 50 bytes written]

CRC32 mismatch → torn write detected
```

**Recovery:** Truncate file at entry N, discard entry.

### Partial Segment Recovery

If segment header is corrupt:

```
1. Attempt to parse header
2. If magic/version invalid: segment is unusable
3. Log error, skip segment (data loss!)
4. Continue with next segment
```

**Mitigation:** Always fsync header before writing entries.

### Example Recovery Code

```elixir
defmodule Storage.WAL.Recovery do
  def recover_segment(file_path) do
    {:ok, handle} = :file.open(file_path, [:read, :binary])

    # Read header
    {:ok, header_bytes} = :file.read(handle, 64)
    {:ok, header} = parse_header(header_bytes)

    # Validate magic
    if header.magic != <<0x53, 0x48, 0x41, 0x4E, 0x47, 0x41>> do
      {:error, :invalid_magic}
    else
      recover_entries(handle, header)
    end
  end

  defp recover_entries(handle, header) do
    recover_entries_loop(handle, header.first_lsn, [])
  end

  defp recover_entries_loop(handle, expected_lsn, acc) do
    case read_entry(handle) do
      {:ok, entry} ->
        if valid_crc32?(entry) do
          recover_entries_loop(handle, expected_lsn + 1, [entry | acc])
        else
          # Torn write, truncate here
          {:ok, offset} = :file.position(handle, :cur)
          :file.truncate(handle)
          {:partial_recovery, Enum.reverse(acc), expected_lsn}
        end

      :eof ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_crc32?(entry) do
    expected_crc = entry.crc32
    actual_crc = :erlang.crc32(entry.data)
    expected_crc == actual_crc
  end
end
```

## Compaction

### When to Compact

Compact old segments when:

- **Disk space low**: Free up space by deleting old data
- **Replication caught up**: All followers have replicated entries
- **Retention expired**: Data older than N days

### Compaction Algorithm

```
1. Identify segments to compact
   - All entries replicated to followers
   - Older than retention period

2. For each segment:
   a. Verify all replicas have acked entries
   b. Close segment file handle
   c. Delete file from filesystem

3. Update metadata
```

### Example Compaction Code

```elixir
defmodule Storage.WAL.Compactor do
  def compact_old_segments(retention_days) do
    cutoff_time = System.system_time(:millisecond) - (retention_days * 86400 * 1000)

    segments = list_all_segments()

    segments
    |> Enum.filter(fn seg -> seg.created < cutoff_time end)
    |> Enum.filter(&all_replicas_acked?/1)
    |> Enum.each(&delete_segment/1)
  end

  defp all_replicas_acked?(segment) do
    # Check that all replication groups have acked segment.last_lsn
    groups = Replication.all_groups()

    Enum.all?(groups, fn group ->
      group.follower_offset >= segment.last_lsn
    end)
  end

  defp delete_segment(segment) do
    File.rm(segment.path)
    Logger.info("Compacted segment #{segment.id}")
  end
end
```

## Implementation Notes

### Concurrency

- **Single writer**: Only one process writes to active segment
- **Multiple readers**: Many processes can read sealed segments
- **No locking on sealed segments**: Immutable after sealing

### fsync() Behavior

Shanghai uses `fsync()` to ensure durability:

```elixir
# Write entry
:file.write(handle, entry_bytes)

# Sync to disk
:file.sync(handle)
```

**Performance:** `fsync()` is expensive (~5-10ms). Use batching for higher throughput.

### Batching

Group multiple writes before `fsync()`:

```elixir
# Write 100 entries
Enum.each(entries, fn entry ->
  :file.write(handle, entry_bytes)
end)

# Single fsync for all 100
:file.sync(handle)
```

**Trade-off:** Higher throughput, slightly higher latency.

### Error Handling

| Error | Behavior |
|-------|----------|
| Disk full | Reject writes, return `{:error, :disk_full}` |
| Corrupt entry | Truncate segment at corruption point |
| Missing segment | Attempt recovery, report data loss |
| I/O error | Crash process, supervisor restarts |

## Versioning and Compatibility

### Forward Compatibility

Newer readers can read old format:

- Version 2 reader can read Version 1 segments
- Ignore unknown header fields (Reserved bytes)

### Backward Compatibility

Older readers **cannot** read new format:

- Version 1 reader will reject Version 2 segments
- Check version field in header first

### Version History

| Version | Released | Changes |
|---------|----------|---------|
| 1 | 2025-01 | Initial format |

## Security Considerations

### Checksum Limitations

CRC32 detects **accidental corruption**, not malicious tampering.

**Not secure against:**
- Intentional data modification
- Birthday attacks on CRC32

**Use encryption** if data integrity against attackers is required.

### File Permissions

WAL files should be:

```bash
-rw------- 1 shanghai shanghai  segment_00001.wal
```

**Only the Shanghai process** should have read/write access.

## References

- **CRC-32 Standard:** ISO/IEC 13239
- **BEAM file I/O:** https://erlang.org/doc/man/file.html
- **Write-Ahead Logging:** Gray & Reuter, "Transaction Processing"

## See Also

- [Replication Protocol](REPLICATION_PROTOCOL.md)
- [Architecture Guide](../ARCHITECTURE.md)
- [Storage Implementation](../../apps/storage/)
