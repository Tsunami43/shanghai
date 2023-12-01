# Shanghai Cluster - Phase 2

Cluster membership and node discovery implementation for Shanghai distributed database.

## Overview

Phase 2 introduces distributed awareness in Shanghai. Each node now understands the cluster topology and can discover, join, and leave other nodes dynamically. This phase does not yet replicate data but lays the foundation for future replication and consensus.

## Architecture

The cluster system is built on three main components supervised by `Cluster.Supervisor`:

```
Cluster.Supervisor
├── Cluster.Membership (GenServer)
├── Cluster.Heartbeat (GenServer)
└── Cluster.Gossip (GenServer)
```

### Components

#### 1. Cluster.Membership

Manages cluster topology and membership state.

**Responsibilities:**
- Maintains the cluster state (Cluster aggregate)
- Handles node join/leave requests
- Tracks Erlang `:nodeup`/`:nodedown` events
- Broadcasts membership events to subscribers
- Provides query interface for cluster state

**Key Operations:**
- `join_node/1` - Add a node to the cluster
- `leave_node/2` - Remove a node from the cluster
- `all_nodes/0` - Get all nodes in the cluster
- `subscribe/0` - Subscribe to membership events

#### 2. Cluster.Heartbeat

Monitors node liveness using heartbeat protocol.

**Responsibilities:**
- Periodically sends heartbeats to all cluster nodes
- Receives and tracks heartbeats from other nodes
- Detects node failures based on missed heartbeats
- Marks nodes as suspect or down when heartbeats are missed
- Notifies Membership process of status changes

**Configuration:**
- `interval_ms` - Heartbeat interval (default: 5000ms)
- `timeout_ms` - Timeout before marking node down (default: 15000ms)
- `suspect_timeout_ms` - Timeout before marking node suspect (default: 10000ms)

**Node States:**
- `:up` - Node is healthy and responding
- `:suspect` - Node missed suspect timeout threshold
- `:down` - Node missed full timeout threshold

#### 3. Cluster.Gossip

Implements gossip protocol for event propagation.

**Responsibilities:**
- Broadcasts cluster events to all nodes
- Receives and processes gossip messages from other nodes
- Ensures eventual consistency of cluster state
- Manages gossip rounds and fanout
- Prevents message loops using seen-message tracking

**Configuration:**
- `fanout` - Number of nodes to gossip to per round (default: 3)
- `interval_ms` - Gossip interval (default: 1000ms)

**Message Types:**
- `{:heartbeat, Heartbeat.t()}` - Heartbeat messages
- `{:cluster_event, struct()}` - Cluster membership events
- `{:membership_sync, map()}` - Membership state synchronization

## Domain Model (DDD)

### Aggregate: Cluster

The Cluster aggregate owns knowledge of all known nodes and manages the join/leave protocol.

**Operations:**
- `add_node/2` - Add a node and emit `NodeJoined` event
- `remove_node/3` - Remove a node and emit `NodeLeft` event
- `mark_node_down/3` - Mark node as down and emit `NodeDetectedDown` event
- `mark_node_suspect/2` - Mark node as suspect
- `mark_node_up/2` - Mark node as up

### Entity: Node

Represents a node in the cluster.

**Attributes:**
- `id` - NodeId (unique identifier)
- `host` - Hostname or IP address
- `port` - Port number
- `status` - Current status (`:up`, `:down`, `:suspect`)
- `metadata` - Additional node metadata
- `last_seen_at` - Timestamp of last activity

### Domain Events

Events emitted by the cluster:

1. **NodeJoined** - A node successfully joined the cluster
   - `node_id` - ID of the joined node
   - `node` - Full node entity
   - `timestamp` - When the event occurred

2. **NodeLeft** - A node left the cluster
   - `node_id` - ID of the departed node
   - `reason` - Why the node left (`:graceful`, `:timeout`, `:requested`)
   - `timestamp` - When the event occurred

3. **NodeDetectedDown** - A node was detected as down
   - `node_id` - ID of the failed node
   - `detection_method` - How it was detected (`:heartbeat_failure`, `:network_partition`, `:manual`)
   - `timestamp` - When the event occurred

### Value Objects

1. **Heartbeat** - Represents a heartbeat signal
   - `node_id` - Source node ID
   - `sequence` - Monotonically increasing sequence number
   - `timestamp` - When the heartbeat was created
   - `metrics` - Optional health metrics

2. **NodeMetadata** - Additional node information
   - `capabilities` - Set of node capabilities
   - `tags` - Custom tags and labels
   - `resources` - Resource availability information
   - `version` - Node version

## Protocols

### Node Join Protocol

1. Node creates a `Node` entity with its connection information
2. Node calls `Cluster.join/1` with the node entity
3. Membership validates the node doesn't already exist
4. Cluster aggregate adds the node and emits `NodeJoined` event
5. Event is broadcast to all subscribers
6. Gossip propagates the event to other nodes

### Node Leave Protocol

1. Node (or operator) calls `Cluster.leave/2` with node ID and reason
2. Membership validates the node exists
3. Cluster aggregate removes the node and emits `NodeLeft` event
4. Event is broadcast to all subscribers
5. Gossip propagates the event to other nodes

### Heartbeat Protocol

1. Each node sends heartbeats at configured interval
2. Heartbeats include sequence number and optional metrics
3. Receiving node records the heartbeat and timestamp
4. Heartbeat process periodically checks all tracked heartbeats
5. If heartbeat age exceeds `suspect_timeout_ms`, mark node as suspect
6. If heartbeat age exceeds `timeout_ms`, mark node as down and emit event
7. Fresh heartbeats reset the timeout counters

### Gossip Protocol

1. Each node maintains a message buffer of events to propagate
2. At each gossip interval, select random subset of nodes (fanout)
3. Send all buffered messages to selected nodes
4. Clear buffer after successful gossip
5. Receiving nodes:
   - Check if message was already seen (prevent loops)
   - Process the message (e.g., record heartbeat, update membership)
   - Add message to their own buffer for re-gossip
   - Mark message as seen

## Usage

### Starting the Cluster

The cluster starts automatically with the application:

```elixir
# In your application supervision tree
{Cluster.Application, []}
```

### Joining Nodes

```elixir
# Create a node entity
node_id = CoreDomain.Types.NodeId.new("node1")
node = Cluster.Entities.Node.new(node_id, "localhost", 4000)

# Join the cluster
:ok = Cluster.join(node)
```

### Subscribing to Events

```elixir
# Subscribe to cluster events
:ok = Cluster.subscribe()

# Receive events
receive do
  {:cluster_event, %Cluster.Events.NodeJoined{} = event} ->
    IO.puts("Node joined: #{event.node_id.value}")

  {:cluster_event, %Cluster.Events.NodeLeft{} = event} ->
    IO.puts("Node left: #{event.node_id.value}")

  {:cluster_event, %Cluster.Events.NodeDetectedDown{} = event} ->
    IO.puts("Node down: #{event.node_id.value}")
end
```

### Querying Cluster State

```elixir
# Get all nodes
nodes = Cluster.nodes()

# Get specific node
{:ok, node} = Cluster.get_node(node_id)

# Get local node ID
local_id = Cluster.local_node_id()

# Get cluster state
cluster = Cluster.cluster_state()
```

## Failure Handling

The cluster uses OTP supervision with `:one_for_one` strategy:

- If Membership crashes, only Membership is restarted
- If Heartbeat crashes, only Heartbeat is restarted
- If Gossip crashes, only Gossip is restarted

**Event Replay:**
- Membership events are re-broadcast if missed due to crash
- Heartbeat state is rebuilt from incoming heartbeats
- Gossip messages may be lost but will be re-propagated in next round

**Network Partitions:**
- Erlang's `:nodedown` events trigger node down detection
- Heartbeat timeouts provide additional detection mechanism
- Gossip protocol provides eventual consistency

## Testing

Run the test suite:

```bash
mix test
```

Test categories:
- Node entity tests: `test/cluster/entities/node_test.exs`
- Cluster aggregate tests: `test/cluster/cluster_test.exs`
- Membership protocol tests: `test/cluster/membership_test.exs`
- Heartbeat detection tests: `test/cluster/heartbeat_test.exs`
- Gossip propagation tests: `test/cluster/gossip_test.exs`

## Limitations (Phase 2)

Current limitations that will be addressed in future phases:

- **No Data Replication** - Storage is still local and single-node per shard
- **No Sharding** - Data is not distributed across nodes
- **Eventual Consistency Only** - Cluster state uses eventual consistency
- **No Authentication** - Nodes can join without authentication
- **No Encryption** - Communication is not encrypted
- **Basic Gossip** - Simple gossip without anti-entropy or merkle trees

## Next Steps (Phase 3)

Phase 3 will introduce:
- Data replication across nodes
- Consensus protocols (Raft or similar)
- Strong consistency guarantees
- Partition tolerance
- Anti-entropy mechanisms

## References

- Erlang Distribution: https://erlang.org/doc/reference_manual/distributed.html
- Gossip Protocols: "Epidemic Algorithms for Replicated Database Maintenance" (Demers et al.)
- Failure Detection: "The φ Accrual Failure Detector" (Hayashibara et al.)
