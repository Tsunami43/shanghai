# Cluster Membership Protocol Specification

**Version:** 1.0
**Status:** Stable
**Last Updated:** 2025-10-18

This document specifies the cluster membership protocol used by Shanghai for node discovery, failure detection, and cluster state management.

## Table of Contents

- [Overview](#overview)
- [Design Goals](#design-goals)
- [Terminology](#terminology)
- [Node Lifecycle](#node-lifecycle)
- [Heartbeat Protocol](#heartbeat-protocol)
- [Failure Detection](#failure-detection)
- [Membership Events](#membership-events)
- [Gossip Protocol](#gossip-protocol)
- [Split-Brain Handling](#split-brain-handling)

## Overview

Shanghai's cluster membership protocol provides:

- **Node discovery**: Nodes discover each other and form a cluster
- **Failure detection**: Detect node failures via heartbeats
- **State dissemination**: Propagate membership changes via gossip
- **Event notification**: Notify applications of membership changes

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                     Node 1                          │
│                                                     │
│   ┌──────────────┐         ┌──────────────┐       │
│   │  Membership  │────────>│  Heartbeat   │       │
│   │  (state)     │  notify │  (liveness)  │       │
│   └──────┬───────┘         └──────┬───────┘       │
│          │                        │               │
│          │ events                 │ send/receive  │
│          ▼                        ▼               │
│   ┌──────────────┐         ┌──────────────┐       │
│   │ Subscribers  │         │    Gossip    │       │
│   └──────────────┘         └──────┬───────┘       │
│                                   │               │
└───────────────────────────────────┼───────────────┘
                                    │
                                    │ gossip messages
                                    ▼
┌───────────────────────────────────┼───────────────┐
│                     Node 2        │               │
│                                   ▼               │
│                            ┌──────────────┐       │
│                            │    Gossip    │       │
│                            └──────┬───────┘       │
│                                   │               │
└───────────────────────────────────────────────────┘
```

## Design Goals

1. **Eventually consistent**: All nodes converge to same view
2. **Scalable**: Support hundreds of nodes
3. **Resilient**: Tolerate network partitions and node failures
4. **Simple**: Easy to understand and debug

### Non-Goals

- **Strong consistency**: No consensus (Paxos/Raft)
- **Byzantine fault tolerance**: Assumes non-malicious nodes
- **Zero message overhead**: Some background gossip traffic

## Terminology

| Term | Definition |
|------|------------|
| **Node** | A Shanghai process in the cluster |
| **Member** | A node in the cluster membership list |
| **Suspect** | Node that may have failed (missed heartbeats) |
| **Down** | Node confirmed as failed |
| **Up** | Node confirmed as healthy |
| **Heartbeat** | Periodic liveness signal |
| **Gossip** | Probabilistic state dissemination |

## Node Lifecycle

### State Transitions

```
        join_node()
             │
             ▼
        ┌────────┐
        │   Up   │<──────┐
        └───┬────┘       │
            │            │
            │ heartbeat  │
            │ timeout    │ heartbeat
            ▼            │ resumed
        ┌─────────┐     │
        │ Suspect │─────┘
        └───┬─────┘
            │
            │ timeout
            ▼
        ┌────────┐
        │  Down  │
        └───┬────┘
            │
            │ leave_node()
            ▼
        ┌─────────┐
        │ Removed │
        └─────────┘
```

### States

#### Up

Node is healthy and responding to heartbeats.

**Properties:**
- Accepts writes
- Participates in replication
- Sends/receives gossip

**Entry:** Node joins cluster or recovers from suspect

**Exit:** Heartbeat timeout → Suspect

---

#### Suspect

Node missed heartbeats, possibly failed.

**Properties:**
- Still in membership list
- May recover to Up
- Timeout moves to Down

**Entry:** Heartbeat timeout (> 10 seconds)

**Exit:**
- Heartbeat resumed → Up
- Further timeout (> 15 seconds) → Down

---

#### Down

Node failed, not responding.

**Properties:**
- Removed from active membership
- No writes sent
- May be manually removed

**Entry:** Suspect timeout (> 15 seconds)

**Exit:** Manual `leave_node()` → Removed

---

## Heartbeat Protocol

### Overview

Heartbeats are periodic UDP messages proving liveness.

### Heartbeat Message

```elixir
%Heartbeat{
  node_id: NodeId.t(),
  timestamp: integer(),  # Unix milliseconds
  sequence: integer()    # Monotonically increasing
}
```

### Sending Heartbeats

Every node sends heartbeats every **5 seconds**:

```elixir
defmodule Cluster.Heartbeat do
  @interval_ms 5_000

  def init(_opts) do
    schedule_heartbeat(@interval_ms)
    {:ok, state}
  end

  def handle_info(:send_heartbeat, state) do
    heartbeat = %Heartbeat{
      node_id: state.local_node_id,
      timestamp: System.system_time(:millisecond),
      sequence: state.sequence
    }

    broadcast_heartbeat(heartbeat)
    schedule_heartbeat(@interval_ms)

    {:noreply, %{state | sequence: state.sequence + 1}}
  end
end
```

### Broadcasting Heartbeats

Heartbeats are broadcast via **Erlang message passing**:

```elixir
defp broadcast_heartbeat(heartbeat) do
  nodes = Cluster.Membership.all_nodes()

  Enum.each(nodes, fn node ->
    erlang_node = erlang_node_name(node)
    send({Cluster.Heartbeat, erlang_node}, {:heartbeat, heartbeat})
  end)
end
```

### Receiving Heartbeats

```elixir
def handle_cast({:record_heartbeat, heartbeat}, state) do
  node_id = heartbeat.node_id

  heartbeat_state = %{
    last_heartbeat: heartbeat,
    missed_count: 0
  }

  updated_heartbeats = Map.put(state.heartbeats, node_id, heartbeat_state)

  # Emit telemetry
  age_ms = Heartbeat.age_ms(heartbeat)
  Observability.Metrics.heartbeat_completed(age_ms, node_id.value)

  {:noreply, %{state | heartbeats: updated_heartbeats}}
end
```

### Heartbeat Checking

Every **5 seconds**, check all heartbeats:

```elixir
def handle_info(:check_heartbeats, state) do
  Enum.each(state.heartbeats, fn {node_id, hb_state} ->
    age_ms = Heartbeat.age_ms(hb_state.last_heartbeat)

    cond do
      age_ms >= 15_000 ->
        # Down
        GenServer.cast(Cluster.Membership, {:mark_down, node_id, :heartbeat_failure})

      age_ms >= 10_000 ->
        # Suspect
        GenServer.cast(Cluster.Membership, {:mark_suspect, node_id})

      true ->
        # Healthy
        :ok
    end
  end)

  schedule_check(state.interval_ms)
  {:noreply, state}
end
```

## Failure Detection

### Timeouts

| Timeout | Threshold | Action |
|---------|-----------|--------|
| Suspect | 10 seconds | Mark node as suspect |
| Down | 15 seconds | Mark node as down |

### Detection Methods

Shanghai uses multiple failure detection methods:

#### 1. Heartbeat-Based (Primary)

Monitors heartbeat age:

```elixir
age_ms = System.system_time(:millisecond) - heartbeat.timestamp

if age_ms > 15_000 do
  mark_node_down(node_id, :heartbeat_failure)
end
```

#### 2. Erlang Node Monitoring (Secondary)

Monitors Erlang `:nodeup`/`:nodedown` events:

```elixir
def init(_opts) do
  :net_kernel.monitor_nodes(true, node_type: :visible)
  {:ok, state}
end

def handle_info({:nodedown, erlang_node, _info}, state) do
  node_id = find_node_by_erlang_name(state.cluster, erlang_node)

  if node_id do
    mark_node_down(node_id, :network_partition)
  end

  {:noreply, state}
end
```

### False Positive Mitigation

To reduce false positives:

1. **Suspect state**: Grace period before marking down
2. **Quick recovery**: Heartbeat resume moves suspect → up
3. **Tunable timeouts**: Adjust for network conditions

## Membership Events

### Event Types

```elixir
# Node joined cluster
%NodeJoined{
  node_id: NodeId.t(),
  timestamp: integer()
}

# Node left cluster (graceful)
%NodeLeft{
  node_id: NodeId.t(),
  reason: :graceful | :forced,
  timestamp: integer()
}

# Node detected as down (failure)
%NodeDetectedDown{
  node_id: NodeId.t(),
  detection_method: :heartbeat_failure | :network_partition,
  timestamp: integer()
}
```

### Event Broadcasting

Membership events are broadcast to subscribers:

```elixir
defp broadcast_events(events, subscribers) do
  Enum.each(events, fn event ->
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:cluster_event, event})
    end)
  end)
end
```

### Subscribing to Events

```elixir
# Subscribe
:ok = Cluster.Membership.subscribe()

# Receive events
receive do
  {:cluster_event, %NodeJoined{node_id: id}} ->
    Logger.info("Node #{id.value} joined")

  {:cluster_event, %NodeLeft{node_id: id, reason: reason}} ->
    Logger.info("Node #{id.value} left: #{reason}")

  {:cluster_event, %NodeDetectedDown{node_id: id, detection_method: method}} ->
    Logger.warning("Node #{id.value} down (#{method})")
end
```

## Gossip Protocol

### Overview

Gossip disseminates membership state across the cluster.

**Status:** Basic gossip implemented, full epidemic gossip in v2.0.

### Gossip Message

```elixir
%GossipMessage{
  type: :membership_update,
  sender_id: NodeId.t(),
  view: %{
    nodes: [%Node{...}, ...],
    version: integer()
  },
  timestamp: integer()
}
```

### Gossip Algorithm

Every **1 second**, each node:

1. Select K random nodes (K=3)
2. Send current membership view
3. Receive views from others
4. Merge views (take latest version)

```elixir
defmodule Cluster.Gossip do
  @gossip_interval_ms 1_000
  @gossip_fanout 3

  def handle_info(:gossip, state) do
    # Select random nodes
    targets = select_random_nodes(state.cluster, @gossip_fanout)

    # Send membership view
    message = %GossipMessage{
      type: :membership_update,
      sender_id: state.local_node_id,
      view: build_membership_view(state.cluster),
      timestamp: System.system_time(:millisecond)
    }

    Enum.each(targets, fn node ->
      send_gossip(node, message)
    end)

    schedule_gossip(@gossip_interval_ms)
    {:noreply, state}
  end

  def handle_cast({:gossip_message, message}, state) do
    # Merge remote view into local view
    updated_cluster = merge_views(state.cluster, message.view)
    {:noreply, %{state | cluster: updated_cluster}}
  end
end
```

### View Merging

When merging views, take node with higher version:

```elixir
defp merge_views(local_view, remote_view) do
  Enum.reduce(remote_view.nodes, local_view, fn remote_node, acc_view ->
    case find_node(acc_view, remote_node.id) do
      nil ->
        # New node, add it
        add_node(acc_view, remote_node)

      local_node ->
        # Existing node, take newer version
        if remote_node.version > local_node.version do
          update_node(acc_view, remote_node)
        else
          acc_view
        end
    end
  end)
end
```

## Split-Brain Handling

### Problem

Network partition can cause split-brain:

```
Partition:
  Side A: [node-1, node-2]
  Side B: [node-3, node-4]

Both sides think the other is down.
```

### Detection

Nodes detect partition when:

1. Erlang `:nodedown` events received
2. Heartbeats stop from subset of nodes
3. Gossip messages stop arriving

### Behavior During Partition

Shanghai allows **multi-master** writes during partition:

- Both sides continue accepting writes
- No automatic reconciliation
- Manual intervention required after partition heals

**Example:**

```
Before partition:
  Offset 1-100: written to all nodes

During partition:
  Side A writes: offsets 101-200
  Side B writes: offsets 101-150 (divergent!)

After partition heals:
  Conflict: both have offset 101 with different data
  Resolution: Manual (application-specific)
```

### Future Work

v2.0 will include:

- **Quorum-based writes**: Require majority nodes
- **Vector clocks**: Track causality
- **Automatic conflict resolution**: CRDTs

## Configuration

### Timeouts

```elixir
# config/config.exs
config :cluster,
  # Heartbeat interval
  heartbeat_interval_ms: 5_000,

  # Mark suspect after N ms without heartbeat
  suspect_timeout_ms: 10_000,

  # Mark down after N ms without heartbeat
  down_timeout_ms: 15_000,

  # Gossip interval
  gossip_interval_ms: 1_000,

  # Gossip fanout (nodes per round)
  gossip_fanout: 3
```

### Tuning for Network Conditions

**Low-latency LAN:**
```elixir
config :cluster,
  heartbeat_interval_ms: 2_000,
  suspect_timeout_ms: 6_000,
  down_timeout_ms: 10_000
```

**High-latency WAN:**
```elixir
config :cluster,
  heartbeat_interval_ms: 10_000,
  suspect_timeout_ms: 30_000,
  down_timeout_ms: 60_000
```

## Performance Characteristics

### Message Overhead

| Metric | Value |
|--------|-------|
| Heartbeat size | ~100 bytes |
| Heartbeats per node | 1 per 5 seconds |
| Gossip message size | ~1 KB (10 nodes) |
| Gossip messages per node | 3 per second |

**Cluster of 10 nodes:**
- Heartbeat traffic: 10 nodes × 100 bytes × 12/min = 12 KB/min
- Gossip traffic: 10 nodes × 1 KB × 180/min = 1.8 MB/min

**Total:** ~2 MB/min for 10-node cluster

### Convergence Time

Time for membership change to propagate:

| Cluster Size | Convergence Time (P99) |
|--------------|------------------------|
| 3 nodes | <1 second |
| 10 nodes | <3 seconds |
| 50 nodes | <10 seconds |
| 100 nodes | <20 seconds |

### Detection Latency

Time to detect node failure:

- **Best case:** 10 seconds (suspect timeout)
- **Worst case:** 15 seconds (down timeout)
- **Erlang nodedown:** Immediate (if Erlang detects first)

## Security Considerations

### Authentication

Shanghai relies on **Erlang cookie** for inter-node authentication:

```bash
# All nodes must share same cookie
iex --name node1@127.0.0.1 --cookie shanghai_secret
```

**Limitations:**
- Symmetric key (all nodes share)
- No per-node credentials
- Cookie transmitted in plaintext (use TLS!)

### Authorization

No authorization in v1.0. All cluster members have equal privileges.

**Future:** Role-based access control (RBAC).

### Encryption

Erlang distribution can use TLS:

```elixir
# config/sys.config
[{kernel, [
  {inet_dist_use_interface, {0,0,0,0}},
  {inet_dist_listen_min, 9100},
  {inet_dist_listen_max, 9155}
]},
{ssl, [
  {client_options, [...]},
  {server_options, [...]}
]}]
```

## Monitoring

### Telemetry Events

```elixir
# Membership change
[:shanghai, :cluster, :membership, :changed]
# Measurements: %{node_count: N}
# Metadata: %{event_type: :node_joined | :node_left | :node_down, node_id: id}

# Heartbeat received
[:shanghai, :cluster, :heartbeat, :completed]
# Measurements: %{rtt: ms}
# Metadata: %{from_node: id, to_node: id}
```

### Metrics to Monitor

- **Node count**: Alert if drops below threshold
- **Heartbeat RTT**: Alert if P99 > 100ms
- **Suspect count**: Alert if > 0
- **Down count**: Alert if > 0

### Example Alerts

```elixir
:telemetry.attach(
  "cluster-alerts",
  [:shanghai, :cluster, :membership, :changed],
  fn _event, measurements, metadata, _config ->
    if measurements.node_count < 3 do
      alert("Cluster under-replicated: #{measurements.node_count} nodes")
    end

    if metadata.event_type == :node_down do
      alert("Node down: #{metadata.node_id}")
    end
  end,
  nil
)
```

## See Also

- [Heartbeat Implementation](../../apps/cluster/lib/cluster/heartbeat.ex)
- [Membership Implementation](../../apps/cluster/lib/cluster/membership.ex)
- [Replication Protocol](REPLICATION_PROTOCOL.md)
- [Architecture Guide](../ARCHITECTURE.md)
