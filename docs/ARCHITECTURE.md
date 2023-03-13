# Shanghai Architecture

This document provides a comprehensive overview of Shanghai's architecture, design principles, and internal components.

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
| Throughput | 10K+ writes/sec (single node) |
| Latency | <5ms P99 (write ack) |

## Design Principles

### 1. Simplicity Over Complexity

Shanghai favors simple, understandable designs over complex optimizations. Each component has a single, well-defined responsibility.

**Example**: Separate GenServers for Segment, Writer, BatchWriter rather than a monolithic storage engine.

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
- **Storage.WAL.BatchWriter**: Batched writes for throughput
- **Storage.WAL.Compactor**: Background segment compaction

#### Example: Writing to WAL

```elixir
# Simple write
{:ok, lsn} = Storage.WAL.Writer.append(data)

# With LSN tracking
lsn = Storage.WAL.Writer.append!(data)
Logger.info("Wrote at LSN #{lsn}")

# Batched writes (higher throughput)
{:ok, lsn} = Storage.WAL.BatchWriter.append(data)
```

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
  │ (batching enabled?)
  ├─ No ──> Storage.WAL.Segment
  │           │
  │           │ write + fsync
  │           ▼
  │         Disk
  │
  └─ Yes ──> Storage.WAL.BatchWriter
              │
              │ batch for 10ms or 100 entries
              ▼
            Storage.WAL.Segment
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

- **Batch writes**: 60x throughput improvement
- **Async replication**: Non-blocking writes
- **Concurrent segment writes**: Multiple WAL segments

**Benchmarks** (single node):
- Sequential writes: 11,000/sec
- Concurrent writes (10 processes): 15,000/sec
- P99 latency: <5ms

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
- **Segment compaction**: Removes old data

### Network Partitions

During network partition:
- **Split-brain possible**: Multi-master allows divergent writes
- **Manual reconciliation**: Operators must resolve conflicts
- **Future work**: Automatic conflict resolution

## Performance Characteristics

### Latency

| Operation | P50 | P95 | P99 |
|-----------|-----|-----|-----|
| WAL write (unbatched) | 0.8ms | 2.1ms | 4.5ms |
| WAL write (batched) | 0.2ms | 0.8ms | 2.0ms |
| Replication (LAN) | 5ms | 15ms | 30ms |
| Heartbeat RTT | 1ms | 3ms | 8ms |

### Throughput

| Workload | Throughput |
|----------|------------|
| Sequential writes (1 KB) | 11,000/sec |
| Concurrent writes (10 processes) | 15,000/sec |
| Batched writes (100 batch size) | 60,000/sec |

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
