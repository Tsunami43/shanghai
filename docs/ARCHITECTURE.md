# Shanghai Architecture

This document provides a comprehensive overview of Shanghai's architecture, design principles, and internal components.

> **Scope & sources.** This is the system-level overview (design principles,
> data flow, fault tolerance). For the domain-driven bounded-context breakdown
> and the **implementation-status table** (what is built vs. targeted), see the
> repository-root [`ARCHITECTURE.md`](../ARCHITECTURE.md). Parts of this document
> describe target capabilities (e.g. multi-master replication, batched
> throughput) that are not yet fully implemented; treat capability claims as
> design intent unless confirmed by the status table.

## Table of Contents

- [Overview](#overview)
- [Design Principles](#design-principles)
- [System Architecture](#system-architecture)
- [Core Components](#core-components)
- [Data Flow](#data-flow)
- [Scalability Model](#scalability-model)
- [Fault Tolerance](#fault-tolerance)
- [Performance Characteristics](#performance-characteristics)

## Overview

Shanghai is a distributed, replicated log storage system built on the Erlang VM (BEAM). It provides:

- **Durable storage** via Write-Ahead Log (WAL)
- **Multi-master replication** with configurable consistency
- **Cluster membership** with failure detection
- **High throughput** through batching and async replication
- **Operational simplicity** with built-in observability

### Key Characteristics

| Property | Value |
|----------|-------|
| Written in | Elixir (Erlang/OTP) |
| Storage model | Write-Ahead Log (WAL) |
| Replication | Multi-master, async |
| Consistency | Eventually consistent |
| Throughput | ~10K writes/sec (single node, concurrent, NVMe) |
| Latency | <5ms P99 (write ack) |

## Design Principles

### 1. Simplicity Over Complexity

Shanghai favors simple, understandable designs over complex optimizations. Each component has a single, well-defined responsibility.

**Example**: Separate GenServers for Segment, Writer and Reader rather than a monolithic storage engine.

### 2. Fail-Fast Philosophy

Components detect errors early and crash rather than entering inconsistent states. The BEAM supervisor tree restarts failed processes.

```elixir
# Segment crashes if WAL file is corrupt
def handle_call({:append, entry}, _from, state) do
  case append_to_file(state.file_handle, entry) do
    :ok -> {:reply, :ok, state}
    {:error, reason} ->
      # Crash and let supervisor restart
      raise "WAL append failed: #{reason}"
  end
end
```

### 3. Observable by Default

Every component emits telemetry events for monitoring. No "black boxes" - operators can see what's happening.

```elixir
:telemetry.execute(
  [:shanghai, :wal, :write],
  %{duration: duration_ms, bytes: byte_size},
  %{segment_id: segment_id}
)
```

### 4. Location Transparency

Distributed operations look identical to local operations. GenServers abstract physical node boundaries.

```elixir
# Works whether Membership is local or remote
Cluster.Membership.join_node(node)
```

## System Architecture

### High-Level View

```
┌─────────────────────────────────────────────────────────┐
│                    Shanghai Node                        │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │   Cluster    │  │   Storage    │  │ Replication  │ │
│  │  (membership │  │    (WAL)     │  │   (sync)     │ │
│  │   heartbeat) │  │              │  │              │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                 │         │
│         └─────────┬───────┴─────────┬───────┘         │
│                   │                 │                 │
│            ┌──────▼─────────────────▼──────┐          │
│            │   Observability (telemetry)   │          │
│            └───────────────────────────────┘          │
│                                                         │
│  ┌──────────────┐                  ┌──────────────┐   │
│  │  Admin API   │                  │  CLI (ctl)   │   │
│  │  (HTTP/JSON) │                  │              │   │
│  └──────────────┘                  └──────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Layer Architecture

Shanghai uses a layered architecture:

1. **Application Layer**: CLI and Admin API
2. **Service Layer**: Cluster, Storage, Replication apps
3. **Core Domain**: Value objects, entities, aggregates
4. **Infrastructure**: File I/O, network, telemetry

## Core Components

### 1. Storage Subsystem

The Storage subsystem manages durable, sequential write-ahead log storage.

#### Components

- **Storage.WAL.Segment**: Individual WAL file management
- **Storage.WAL.Writer**: High-level write API
- **Storage.Compaction.Compactor**: Background segment compaction (merges a
  group into one segment; never discards entries)

#### Example: Writing to WAL

```elixir
# Simple write
{:ok, lsn} = Storage.WAL.Writer.append(data)

# With LSN tracking
lsn = Storage.WAL.Writer.append!(data)
Logger.info("Wrote at LSN #{lsn}")
```

Writes are group-committed automatically: concurrent appends share one fsync,
and each caller blocks until its own entry is durable.

#### WAL File Format

```
┌────────────────────────────────────────┐
│  Segment Header (64 bytes)             │
│  - Magic: 0x5348414E4741               │
│  - Version: 1                          │
│  - Segment ID: UUID                    │
│  - Created: Unix timestamp             │
├────────────────────────────────────────┤
│  Entry 1:                              │
│    - Length: uint32 (4 bytes)          │
│    - CRC32: uint32 (4 bytes)           │
│    - Data: variable length             │
├────────────────────────────────────────┤
│  Entry 2:                              │
│    - Length: uint32                    │
│    - CRC32: uint32                     │
│    - Data: variable length             │
├────────────────────────────────────────┤
│  ...                                   │
└────────────────────────────────────────┘
```

### 2. Cluster Subsystem

Manages cluster membership and failure detection.

#### Components

- **Cluster.Membership**: Cluster state management
- **Cluster.Heartbeat**: Liveness detection
- **Cluster.Gossip**: State dissemination
- **Cluster.State**: Cluster aggregate

#### Example: Cluster Operations

```elixir
# Join a node to cluster
node = Cluster.Entities.Node.new(
  node_id: NodeId.new("node-2"),
  host: "10.0.1.11",
  port: 4000
)
:ok = Cluster.Membership.join_node(node)

# Get all cluster nodes
nodes = Cluster.Membership.all_nodes()

# Subscribe to membership events
:ok = Cluster.Membership.subscribe()
receive do
  {:cluster_event, %NodeJoined{node_id: id}} ->
    IO.puts("Node #{id} joined")
end
```

#### Failure Detection

Shanghai uses **heartbeat-based** failure detection:

1. Every node sends heartbeats every 5 seconds
2. If heartbeat > 10s old: mark node **suspect**
3. If heartbeat > 15s old: mark node **down**
4. If heartbeat resumes: mark node **up**

```elixir
# Heartbeat state machine
:up -> :suspect -> :down
         ↑          |
         └──────────┘
       (recovery)
```

### 3. Replication Subsystem

Provides asynchronous multi-master replication with backpressure.

#### Components

- **Replication.Leader**: Sends log entries to followers
- **Replication.Follower**: Receives and applies entries
- **Replication.Monitor**: Tracks replication lag
- **Replication.CreditController**: Backpressure mechanism

#### Example: Replication

```elixir
# Start replicating to a follower
{:ok, pid} = Replication.Leader.start_link(
  follower_node_id: NodeId.new("node-2"),
  start_offset: 0
)

# Check replication status
groups = Replication.all_groups()
#=> [%{
#  follower: "node-2",
#  leader_offset: 10000,
#  follower_offset: 9950,
#  lag: 50,
#  status: :replicating
#}]
```

#### Credit-Based Flow Control

Shanghai implements **credit-based backpressure** to prevent unbounded memory growth:

```
Leader                    Follower
  |                          |
  |--- initial credit: 100 ->|
  |                          |
  |--- send 10 entries ----->|
  |    (credit -= 10)        |
  |                          |
  |<-- ack + credit: 20 -----|
  |    (credit += 20)        |
  |                          |
  |--- send 10 entries ----->|
  |                          |
```

When credit reaches 0, leader **pauses** replication until follower sends more credit.

### 4. Observability Subsystem

Built-in telemetry for monitoring and debugging.

#### Telemetry Events

All components emit structured telemetry events:

```elixir
# WAL write completed
[:shanghai, :wal, :write, :completed]
# Measurements: %{duration: ms, bytes: count}
# Metadata: %{segment_id: id}

# Heartbeat received
[:shanghai, :cluster, :heartbeat, :completed]
# Measurements: %{rtt: ms}
# Metadata: %{from_node: id, to_node: id}

# Replication lag changed
[:shanghai, :replication, :lag, :changed]
# Measurements: %{lag: offset_count}
# Metadata: %{follower: id, leader: id}
```

#### Example: Telemetry Handler

```elixir
defmodule MyApp.TelemetryHandler do
  def handle_event([:shanghai, :wal, :write, :completed], measurements, metadata, _config) do
    if measurements.duration > 50 do
      Logger.warning("Slow WAL write: #{measurements.duration}ms",
        segment: metadata.segment_id
      )
    end
  end
end

# Attach handler
:telemetry.attach_many(
  "my-handler",
  [
    [:shanghai, :wal, :write, :completed],
    [:shanghai, :cluster, :heartbeat, :completed]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

## Data Flow

### Write Path

```
Client
  │
  │ append(data)
  ▼
Storage.WAL.Writer
  │
  │ assign LSN, write entry (no fsync yet)
  ▼
Storage.WAL.Segment
  │
  │ group commit: one fsync per batch
  │ (flushed immediately when nothing else is queued)
  ▼
Disk
  │
              │ write + fsync (batch)
              ▼
            Disk
```

### Replication Path

```
Leader Node                   Follower Node
     │                             │
     │ WAL append                  │
     ▼                             │
Storage.WAL                        │
     │                             │
     │ notify                      │
     ▼                             │
Replication.Leader                 │
     │                             │
     │ check credit > 0            │
     │                             │
     │ send batch (max 100)        │
     ├────────────────────────────>│
     │                        Replication.Follower
     │                             │
     │                             │ append to WAL
     │                             ▼
     │                        Storage.WAL
     │                             │
     │                             │ ack + return credit
     │<────────────────────────────┤
     │                             │
     │ credit += returned          │
     ▼                             ▼
```

## Scalability Model

### Vertical Scaling

Shanghai scales vertically through:

- **Group commit**: concurrent writes share one fsync
- **Async replication**: Non-blocking writes
- **Concurrent segment writes**: Multiple WAL segments

**Benchmarks** (single node, measured on an NVMe SSD; see
[Performance](PERFORMANCE.md) for hardware and method):
- Sequential writes (single process): ~880/sec - fsync-bound
- Concurrent writes (10 processes): ~5,200/sec
- Concurrent writes (100 processes): ~9,400/sec
- P99 write latency: 3.16ms

### Horizontal Scaling

Shanghai scales horizontally by adding nodes:

```
3-node cluster:
  - 3x storage capacity
  - 3x write throughput (multi-master)
  - N-way replication for durability
```

**Trade-off**: Replication bandwidth increases with node count.

## Fault Tolerance

### Node Failures

Shanghai tolerates node failures through:

1. **Replication**: Each write replicated to N nodes
2. **Automatic failover**: Clients switch to available nodes
3. **Recovery**: Failed nodes catch up via replication

### Data Durability

- **fsync() on every batch**: Ensures durability
- **CRC32 checksums**: Detects corruption

Segment compaction merges a selected group of rotated segments into a single
segment. No entry is discarded, so reads are unaffected and only the
per-segment file headers are reclaimed; the real gains are fewer files and
processes. Truncating entries already covered by a snapshot is not
implemented.

### Network Partitions

During network partition:
- **Within a replication group**: leadership is quorum-gated and fenced, so
  only the majority side can accept writes - see below
- **Across independent writers**: the multi-master model still allows
  divergent writes from clients writing to different groups, and those need
  manual reconciliation
- **Future work**: automatic conflict resolution

#### Leader promotion is quorum-gated and fenced

A node no longer promotes itself just because its local membership view makes
it the smallest node up. Promotion runs an election:

1. The candidate takes the next **epoch** - a monotonically increasing
   leadership term - and asks every configured member for a vote.
2. A member grants at most one vote per epoch, and refuses a candidate whose
   log is less up-to-date than its own. "Up-to-date" is compared as
   `(last_entry_epoch, offset)` lexicographically, the same rule Raft uses: a
   higher last epoch wins regardless of offset, so a longer but staler log
   cannot beat a shorter, fresher one.
3. The candidate leads only with a **strict majority**. An unreachable member
   is a missing vote, so an isolated candidate loses and takes no role at all
   rather than writing unfenced. It retries on the next reconcile.

Every replicated entry then carries its leader's epoch, and a follower drops
an entry from an epoch older than the highest it has seen. A leader that was
deposed - or partitioned away and superseded - cannot keep writing to
followers that have moved on.

Together these prevent a partition from producing two writable leaders: only
the majority side can win an election, and the minority side is fenced out of
the followers it can still reach.

**Cost:** a group of two can no longer fail over. One survivor is not a
majority of two, so it correctly refuses to promote. Fault tolerance needs at
least three members, as with any quorum system.

Votes are persisted before they are granted (atomic write, fsync, rename,
directory fsync), so a node that restarts still remembers what it voted for and
cannot vote twice in one epoch. If that write fails the vote is denied rather
than granted. Set the location with `config :replication, :epoch_dir`; it
defaults to `<data_root>/replication/epochs`. Configure neither and the store
runs in memory and warns - the quorum guarantee then holds only while no member
restarts.

#### What this still is not

- **A group configured without `:members` runs unfenced.** A majority is only
  meaningful against a fixed group size; without one the old unqualified
  behaviour applies, and the coordinator warns about it.
- **This is not Raft.** The election restriction is Raft's - a candidate must
  be at least as up-to-date by `(last_epoch, offset)` - which rules out
  electing a leader that is behind a majority. What is still missing is Raft's
  **log matching**: a follower checks only that offsets are contiguous, not
  that its previous entry agrees with the leader's, and it never truncates a
  divergent tail applied under a superseded leader. Two logs can therefore
  share a `(last_epoch, offset)` yet differ at an earlier offset. Closing that
  needs the leader to send a previous-entry `(offset, epoch)` for the follower
  to verify, and the follower to truncate on mismatch - which in turn needs a
  storage layer that can roll back applied entries. The WAL is append-only and
  the query store applies mutations in place, so neither supports truncation
  today; that is the concrete reason full log reconciliation is a separate
  project rather than a finishing touch. In practice the contract is: a
  quorum-acknowledged write is safe across a failover; an unacknowledged tail
  may be lost or diverge, and the client was never told it committed.

## Performance Characteristics

### Latency

| Operation | P50 | P95 | P99 |
|-----------|-----|-----|-----|
| WAL write (measured, NVMe) | 1.02ms | 1.11ms | 3.16ms |
| Replication (LAN) | 5ms | 15ms | 30ms |
| Heartbeat RTT | 1ms | 3ms | 8ms |

### Throughput

| Workload | Throughput |
|----------|------------|
| Sequential writes (1 KB, single process) | ~880/sec |
| Concurrent writes (10 processes) | ~5,200/sec |
| Concurrent writes (100 processes) | ~9,400/sec |

### Resource Usage

| Resource | Usage (idle) | Usage (high load) |
|----------|--------------|-------------------|
| Memory | 200 MB | 800 MB |
| CPU | 1% | 40% |
| Disk I/O | 0 MB/s | 50 MB/s |
| Network | 0 MB/s | 20 MB/s |

## See Also

- [Operations Guide](OPERATIONS.md) - Production deployment
- [Performance Tuning](TUNING.md) - Optimization recommendations
- [API Reference](API.md) - Programming interface
- [Protocol Specifications](PROTOCOLS.md) - Wire protocols
