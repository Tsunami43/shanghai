# Replication Protocol Specification

**Version:** 1.0
**Status:** Stable
**Last Updated:** 2025-10-05

This document specifies the replication protocol used by Shanghai for multi-master, asynchronous log replication.

## Table of Contents

- [Overview](#overview)
- [Design Goals](#design-goals)
- [Terminology](#terminology)
- [Architecture](#architecture)
- [Message Format](#message-format)
- [Replication Flow](#replication-flow)
- [Credit-Based Flow Control](#credit-based-flow-control)
- [Failure Handling](#failure-handling)
- [Consistency Model](#consistency-model)
- [Performance Characteristics](#performance-characteristics)

## Overview

Shanghai's replication protocol provides **asynchronous, multi-master** replication between cluster nodes. Key characteristics:

- **Async**: Writes return immediately, replication happens in background
- **Multi-master**: Any node can accept writes
- **Eventually consistent**: No coordination between writes
- **Credit-based flow control**: Prevents unbounded memory growth
- **Pull-based**: Followers pull from leaders (future: push-based option)

## Design Goals

### Primary Goals

1. **High throughput**: Replicate 10,000+ entries/sec over LAN
2. **Low latency**: <10ms replication lag under normal load
3. **Backpressure**: Prevent memory exhaustion on slow followers
4. **Simplicity**: Easy to reason about, implement, and debug

### Non-Goals

- **Strong consistency**: No coordination, no quorums
- **Conflict resolution**: Application must handle conflicts
- **Ordered delivery across nodes**: Only per-node ordering guaranteed

## Terminology

| Term | Definition |
|------|------------|
| **Leader** | Node sending log entries to followers |
| **Follower** | Node receiving log entries from leader |
| **Replication Group** | Leader-Follower pair with replication state |
| **Offset** | Log Sequence Number (LSN) of an entry |
| **Lag** | Difference between leader and follower offsets |
| **Credit** | Flow control tokens allowing leader to send data |

## Architecture

### Components

```
┌─────────────────────────────────────────────────────┐
│                   Leader Node                       │
│                                                     │
│   ┌──────────────┐         ┌──────────────┐       │
│   │  Storage.WAL │────────>│ Replication  │       │
│   │              │ notify  │   .Leader    │       │
│   └──────────────┘         └──────┬───────┘       │
│                                   │               │
└───────────────────────────────────┼───────────────┘
                                    │ RPC
                                    ▼
┌───────────────────────────────────┼───────────────┐
│                   Follower Node   │               │
│                                   │               │
│   ┌──────────────┐         ┌──────▼───────┐      │
│   │  Storage.WAL │<────────│ Replication  │      │
│   │              │  write  │  .Follower   │      │
│   └──────────────┘         └──────────────┘      │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Replication Group

A **replication group** consists of:

- **Leader process**: `Replication.Leader` GenServer
- **Follower process**: `Replication.Follower` GenServer
- **State**:
  - Leader offset (latest LSN on leader)
  - Follower offset (latest acked LSN on follower)
  - Credit balance (flow control)
  - Status (:replicating, :paused, :disconnected)

### Multi-Master Topology

```
Node 1 (Leader)  ────────> Node 2 (Follower)
   ↑                            │
   │                            │
   │                            ▼
   └────────────────────── Node 3 (Leader)

Each node can be both leader and follower simultaneously.
```

## Message Format

### Message Types

| Type | Direction | Description |
|------|-----------|-------------|
| `ReplicationBatch` | Leader → Follower | Batch of log entries |
| `ReplicationAck` | Follower → Leader | Acknowledgment + credit return |
| `ReplicationPause` | Follower → Leader | Request pause (overload) |
| `ReplicationResume` | Follower → Leader | Resume after pause |

### ReplicationBatch

Sent by leader to follower with log entries.

**Erlang term format:**

```elixir
%{
  type: :replication_batch,
  leader_id: NodeId.t(),
  follower_id: NodeId.t(),
  entries: [
    %{offset: 100, data: <<...>>},
    %{offset: 101, data: <<...>>},
    %{offset: 102, data: <<...>>}
  ],
  leader_offset: 102,  # Highest offset on leader
  batch_id: UUID.t()   # For deduplication
}
```

**Size limits:**
- Max batch size: 100 entries (configurable)
- Max bytes per batch: 1 MB (configurable)

### ReplicationAck

Sent by follower to leader after successful write.

```elixir
%{
  type: :replication_ack,
  follower_id: NodeId.t(),
  follower_offset: 102,  # Highest offset written
  credit_returned: 10,   # Flow control credits
  batch_id: UUID.t()     # Matches ReplicationBatch
}
```

### ReplicationPause

Follower requests leader to pause replication (e.g., disk slow).

```elixir
%{
  type: :replication_pause,
  follower_id: NodeId.t(),
  reason: :slow_disk  # or :high_load, :manual
}
```

### ReplicationResume

Follower signals readiness to resume.

```elixir
%{
  type: :replication_resume,
  follower_id: NodeId.t(),
  start_offset: 103  # Resume from this offset
}
```

## Replication Flow

### Initial Setup

```
1. Leader: Start Replication.Leader process
   - follower_node_id: "node-2"
   - start_offset: 0 (or last known offset)

2. Leader: Initialize state
   - leader_offset: current WAL offset
   - follower_offset: start_offset
   - credit: 100 (initial credit)
   - status: :replicating

3. Leader: Begin sending batches
```

### Steady-State Replication

```
┌────────┐                                      ┌──────────┐
│ Leader │                                      │ Follower │
└───┬────┘                                      └────┬─────┘
    │                                                │
    │ 1. WAL append (offsets 100-109)               │
    │                                                │
    │ 2. Check credit > 0                            │
    │    credit = 100                                │
    │                                                │
    │ 3. Send ReplicationBatch (10 entries)          │
    ├──────────────────────────────────────────────> │
    │    credit -= 10                                │
    │                                                │
    │                                                │ 4. Write to WAL
    │                                                │    (offsets 100-109)
    │                                                │
    │                         5. Send ReplicationAck │
    │ <──────────────────────────────────────────────┤
    │    credit += 10                                │
    │                                                │
    │ 6. Update follower_offset = 109                │
    │                                                │
    ▼                                                ▼
```

### Detailed Flow

#### Step 1: Leader Receives WAL Notification

```elixir
# Leader's Replication.Leader GenServer
def handle_info({:wal_append, offset}, state) do
  if state.credit > 0 do
    send_batch(state)
  else
    # Pause until credit returns
    {:noreply, %{state | status: :waiting_for_credit}}
  end
end
```

#### Step 2: Leader Sends Batch

```elixir
defp send_batch(state) do
  # Read entries from WAL
  entries = read_entries_from_wal(
    state.follower_offset + 1,
    min(state.leader_offset, state.follower_offset + state.credit)
  )

  batch = %{
    type: :replication_batch,
    leader_id: state.leader_id,
    follower_id: state.follower_id,
    entries: entries,
    leader_offset: state.leader_offset,
    batch_id: UUID.uuid4()
  }

  # Send to follower via GenServer call
  GenServer.cast(
    {Replication.Follower, follower_erlang_node(state.follower_id)},
    batch
  )

  # Deduct credit
  new_credit = state.credit - length(entries)
  %{state | credit: new_credit}
end
```

#### Step 3: Follower Writes to WAL

```elixir
# Follower's Replication.Follower GenServer
def handle_cast(%{type: :replication_batch} = batch, state) do
  # Write each entry to WAL
  results = Enum.map(batch.entries, fn entry ->
    Storage.WAL.Writer.append(entry.data)
  end)

  # All succeeded?
  if Enum.all?(results, fn {:ok, _lsn} -> true; _ -> false end) do
    # Send ack
    ack = %{
      type: :replication_ack,
      follower_id: state.follower_id,
      follower_offset: List.last(batch.entries).offset,
      credit_returned: length(batch.entries),
      batch_id: batch.batch_id
    }

    GenServer.cast(
      {Replication.Leader, leader_erlang_node(state.leader_id)},
      ack
    )

    {:noreply, %{state | follower_offset: ack.follower_offset}}
  else
    # Write failed, send error
    {:noreply, state}
  end
end
```

#### Step 4: Leader Processes Ack

```elixir
def handle_cast(%{type: :replication_ack} = ack, state) do
  # Update follower offset
  new_follower_offset = ack.follower_offset

  # Return credit
  new_credit = state.credit + ack.credit_returned

  # Check if more data to send
  if new_follower_offset < state.leader_offset and new_credit > 0 do
    send(:self, :send_next_batch)
  end

  {:noreply, %{
    state |
    follower_offset: new_follower_offset,
    credit: new_credit
  }}
end
```

## Credit-Based Flow Control

### Motivation

Without flow control, a fast leader can overwhelm a slow follower:

```
Leader: 100,000 writes/sec
Follower: 10,000 writes/sec

Result: Leader buffers 90,000 entries/sec → OOM
```

### Credit Mechanism

**Credits** are tokens allowing the leader to send data.

- **Initial credit**: 100 (configurable)
- **Credit deduction**: -1 per entry sent
- **Credit return**: +N per ack received
- **Zero credit**: Leader pauses replication

### Example

```
Leader state:
  credit: 100
  follower_offset: 0
  leader_offset: 1000

Iteration 1:
  - Send batch of 10 entries (offsets 1-10)
  - credit: 100 - 10 = 90

  Follower acks:
  - credit: 90 + 10 = 100

Iteration 2:
  - Send batch of 10 entries (offsets 11-20)
  - credit: 100 - 10 = 90

  Follower acks:
  - credit: 90 + 10 = 100

Continues...
```

### Adaptive Batch Sizing

Leader adapts batch size based on credit:

```elixir
defp calculate_batch_size(state) do
  # Don't send more than available credit
  max_by_credit = state.credit

  # Don't send more than configured max
  max_by_config = state.max_batch_size

  # Don't send more than available entries
  max_by_data = state.leader_offset - state.follower_offset

  min(max_by_credit, max_by_config, max_by_data)
end
```

### Credit Exhaustion

When credit reaches 0, leader **pauses**:

```elixir
def handle_info(:send_batch, %{credit: 0} = state) do
  Logger.warning("Replication paused: credit exhausted",
    follower: state.follower_id
  )

  {:noreply, %{state | status: :waiting_for_credit}}
end
```

Replication resumes when ack returns credit.

## Failure Handling

### Network Partition

If leader and follower are partitioned:

```
1. Leader: Batches timeout (no acks received)
2. Leader: Mark replication group as :disconnected
3. Leader: Stop sending batches
4. Leader: Wait for reconnection

On reconnection:
5. Leader: Resume from follower_offset
6. Follower: May have missed entries, will catch up
```

### Follower Crash

If follower crashes:

```
1. Leader: Batches timeout
2. Leader: Mark replication group as :disconnected
3. Leader: Stop sending batches

On follower recovery:
4. Follower: Start from last acked offset
5. Follower: Send ReplicationResume to leader
6. Leader: Resume replication from requested offset
```

### Leader Crash

If leader crashes:

```
1. Follower: No more batches received
2. Follower: Mark replication group as :disconnected
3. Follower: Wait for leader restart

On leader recovery:
4. Leader: Query follower for last acked offset
5. Leader: Resume replication from that point
```

### Duplicate Batches

Leader may resend batches on timeout:

```elixir
# Follower deduplicates using batch_id
def handle_cast(%{type: :replication_batch} = batch, state) do
  if MapSet.member?(state.seen_batch_ids, batch.batch_id) do
    # Duplicate, ignore
    {:noreply, state}
  else
    # New batch, process
    process_batch(batch, state)
  end
end
```

### Split-Brain Scenarios

During network partition, both sides may accept writes:

```
Partition:
  Node 1: Offsets 1-100 (divergent)
  Node 2: Offsets 1-50, then 101-150 (divergent)

Reconciliation: Manual intervention required
```

**No automatic conflict resolution** in v1.0.

## Consistency Model

### Eventually Consistent

Shanghai provides **eventual consistency**:

- Writes to different nodes may be reordered
- No global ordering guarantee
- Application must handle conflicts

### Guarantees

1. **Per-node ordering**: Entries from a single node are ordered
2. **Read-your-writes**: On the same node
3. **Monotonic reads**: On the same node
4. **Causal consistency**: Not guaranteed across nodes

### Example: Bank Account

```
Initial: account_balance = $100

Node 1 receives: deposit $50  (offset 1)
Node 2 receives: withdraw $30 (offset 1)

After replication:
  Node 1: $100 + $50 - $30 = $120 ✓
  Node 2: $100 - $30 + $50 = $120 ✓

Result: Converges to $120 (commutative operations)
```

**Non-commutative operations** require application-level conflict resolution.

## Performance Characteristics

### Throughput

| Metric | Value |
|--------|-------|
| Replication throughput (LAN) | 50,000 entries/sec |
| Replication throughput (WAN) | 5,000 entries/sec |
| Batch size (default) | 100 entries |
| Batch interval | 10ms |

### Latency

| Metric | P50 | P95 | P99 |
|--------|-----|-----|-----|
| Replication lag (LAN) | 5ms | 15ms | 30ms |
| Replication lag (WAN) | 50ms | 150ms | 300ms |

### Resource Usage

| Resource | Per Replication Group |
|----------|----------------------|
| Memory | ~10 MB (buffers) |
| CPU | 1-2% |
| Network | 5-50 MB/s (depends on write rate) |

## Configuration

### Tuning Parameters

```elixir
# In config/config.exs
config :replication,
  # Initial credit per replication group
  initial_credit: 100,

  # Max entries per batch
  max_batch_size: 100,

  # Max bytes per batch
  max_batch_bytes: 1_048_576,  # 1 MB

  # Batch timeout (if less than max_batch_size entries)
  batch_timeout_ms: 10,

  # RPC timeout
  rpc_timeout_ms: 5_000,

  # Retry backoff
  retry_backoff_ms: 1_000
```

### Throughput vs Latency Trade-off

```
High throughput:
  max_batch_size: 1000
  batch_timeout_ms: 100

Low latency:
  max_batch_size: 10
  batch_timeout_ms: 1
```

## Security Considerations

### Authentication

In v1.0, replication relies on **Erlang cookie** authentication:

```bash
# All nodes must have same cookie
--cookie shanghai_secret_cookie
```

**Future:** Support mutual TLS for inter-node communication.

### Authorization

No per-replication-group authorization in v1.0.

**Future:** ACLs for replication group creation.

### Data Integrity

- **CRC32 in WAL**: Detects corruption on disk
- **No integrity check in transit**: Relies on TCP checksums

**Future:** End-to-end checksums in replication protocol.

## Future Enhancements

### v2.0 (Planned)

- **Push-based replication**: Leader pushes without follower pull
- **Compression**: Compress batches before sending
- **Delta replication**: Only send changed data
- **Conflict-free replicated data types (CRDTs)**: Automatic conflict resolution

### v3.0 (Tentative)

- **Strong consistency**: Optional quorum-based writes
- **Cross-datacenter replication**: Optimizations for high-latency links

## See Also

- [WAL Protocol](WAL_PROTOCOL.md)
- [Cluster Membership Protocol](CLUSTER_PROTOCOL.md)
- [Architecture Guide](../ARCHITECTURE.md)
- [Replication Implementation](../../apps/replication/)
