# Shanghai API Reference

**Version:** 1.2.0
**Last Updated:** 2025-10-12

Complete API reference for Shanghai distributed database system.

## Table of Contents

- [Storage API](#storage-api)
- [Cluster API](#cluster-api)
- [Replication API](#replication-api)
- [Admin API](#admin-api)
- [CLI Commands](#cli-commands)
- [Error Handling](#error-handling)

## Storage API

### Storage.WAL.Writer

High-level API for writing to the Write-Ahead Log.

#### append/1

Appends data to the WAL.

**Signature:**
```elixir
@spec append(binary()) :: {:ok, lsn()} | {:error, reason}
```

**Parameters:**
- `data` (binary): Data to append (max 10 MB per entry)

**Returns:**
- `{:ok, lsn}`: Success, returns Log Sequence Number
- `{:error, :disk_full}`: Insufficient disk space
- `{:error, :invalid_data}`: Data validation failed
- `{:error, reason}`: Other error

**Example:**
```elixir
# Append string data
{:ok, lsn} = Storage.WAL.Writer.append("Hello, World!")
IO.puts("Written at LSN #{lsn}")

# Append binary data
data = :erlang.term_to_binary(%{user_id: 123, action: :login})
{:ok, lsn} = Storage.WAL.Writer.append(data)

# Handle errors
case Storage.WAL.Writer.append(large_data) do
  {:ok, lsn} ->
    Logger.info("Success: LSN #{lsn}")

  {:error, :disk_full} ->
    Logger.error("Out of disk space!")
    cleanup_old_data()

  {:error, reason} ->
    Logger.error("Write failed: #{inspect(reason)}")
end
```

**Performance:**
- Throughput: ~11,000 writes/sec (unbatched)
- Latency: P99 < 5ms

---

#### append!/1

Appends data to the WAL, raises on error.

**Signature:**
```elixir
@spec append!(binary()) :: lsn()
```

**Parameters:**
- `data` (binary): Data to append

**Returns:**
- `lsn`: Log Sequence Number

**Raises:**
- `RuntimeError`: If write fails

**Example:**
```elixir
lsn = Storage.WAL.Writer.append!("Important data")
# Crashes if write fails
```

**Use when:** You want fail-fast behavior.

---

### Storage.WAL.BatchWriter

High-throughput batched writes to the WAL.

#### append/1

Appends data using batching for higher throughput.

**Signature:**
```elixir
@spec append(binary()) :: {:ok, lsn()} | {:error, reason}
```

**Parameters:**
- `data` (binary): Data to append

**Returns:**
- Same as `Storage.WAL.Writer.append/1`

**Example:**
```elixir
# Use BatchWriter for high-throughput workloads
{:ok, lsn} = Storage.WAL.BatchWriter.append(data)
```

**Performance:**
- Throughput: ~60,000 writes/sec (60x improvement)
- Latency: P99 < 2ms (batched)

**Configuration:**
```elixir
# config/config.exs
config :storage, :batch_writer,
  batch_size: 100,       # Max entries per batch
  batch_timeout_ms: 10   # Max wait before flush
```

**Trade-off:** Slightly higher latency, much higher throughput.

---

### Storage.WAL.Reader

Read entries from the WAL (future API).

#### read/1

Reads entry at given LSN.

**Signature:**
```elixir
@spec read(lsn()) :: {:ok, binary()} | {:error, :not_found}
```

**Status:** Not yet implemented in v1.2.0

---

## Cluster API

### Cluster.Membership

Manages cluster membership and node state.

#### start_link/1

Starts the Membership server.

**Signature:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

**Parameters:**
- `opts` (keyword): Options
  - `:node_id` (string | NodeId.t()): Local node ID (optional)

**Example:**
```elixir
# Usually started by supervisor
{:ok, pid} = Cluster.Membership.start_link(node_id: "node-1")
```

---

#### join_node/1

Adds a node to the cluster.

**Signature:**
```elixir
@spec join_node(Node.t()) :: :ok | {:error, atom()}
```

**Parameters:**
- `node` (Node.t()): Node entity to join

**Returns:**
- `:ok`: Node joined successfully
- `{:error, :already_member}`: Node already in cluster
- `{:error, :invalid_node}`: Invalid node data

**Example:**
```elixir
alias Cluster.Entities.Node
alias CoreDomain.Types.NodeId

node = Node.new(
  node_id: NodeId.new("node-2"),
  host: "10.0.1.11",
  port: 4000,
  admin_port: 9090
)

case Cluster.Membership.join_node(node) do
  :ok ->
    IO.puts("Node joined successfully")

  {:error, :already_member} ->
    IO.puts("Node already in cluster")

  {:error, reason} ->
    IO.puts("Failed to join node: #{reason}")
end
```

**Side effects:**
- Broadcasts `NodeJoined` event to subscribers
- Emits telemetry: `[:shanghai, :cluster, :membership, :changed]`

---

#### leave_node/2

Removes a node from the cluster.

**Signature:**
```elixir
@spec leave_node(NodeId.t(), atom()) :: :ok | {:error, atom()}
```

**Parameters:**
- `node_id` (NodeId.t()): ID of node to remove
- `reason` (atom, default: `:graceful`): Reason for leaving

**Returns:**
- `:ok`: Node removed successfully
- `{:error, :not_found}`: Node not in cluster

**Example:**
```elixir
node_id = NodeId.new("node-2")

# Graceful removal
:ok = Cluster.Membership.leave_node(node_id)

# Forced removal
:ok = Cluster.Membership.leave_node(node_id, :forced)
```

**Side effects:**
- Broadcasts `NodeLeft` event
- Emits telemetry

---

#### all_nodes/0

Gets all nodes in the cluster.

**Signature:**
```elixir
@spec all_nodes() :: [Node.t()]
```

**Returns:**
- List of all cluster nodes

**Example:**
```elixir
nodes = Cluster.Membership.all_nodes()

Enum.each(nodes, fn node ->
  IO.puts("Node: #{node.id.value}, Status: #{node.status}")
end)
```

---

#### get_node/1

Gets a specific node by ID.

**Signature:**
```elixir
@spec get_node(NodeId.t()) :: {:ok, Node.t()} | {:error, :not_found}
```

**Parameters:**
- `node_id` (NodeId.t()): Node ID

**Returns:**
- `{:ok, node}`: Node found
- `{:error, :not_found}`: Node not in cluster

**Example:**
```elixir
node_id = NodeId.new("node-2")

case Cluster.Membership.get_node(node_id) do
  {:ok, node} ->
    IO.puts("Node status: #{node.status}")

  {:error, :not_found} ->
    IO.puts("Node not found")
end
```

---

#### local_node_id/0

Gets the local node's ID.

**Signature:**
```elixir
@spec local_node_id() :: NodeId.t()
```

**Returns:**
- Local node ID

**Example:**
```elixir
node_id = Cluster.Membership.local_node_id()
IO.puts("I am node #{node_id.value}")
```

---

#### subscribe/0

Subscribes to cluster membership events.

**Signature:**
```elixir
@spec subscribe() :: :ok
```

**Returns:**
- `:ok`

**Events received:**
- `{:cluster_event, %NodeJoined{node_id: ...}}`
- `{:cluster_event, %NodeLeft{node_id: ..., reason: ...}}`
- `{:cluster_event, %NodeDetectedDown{node_id: ..., method: ...}}`

**Example:**
```elixir
:ok = Cluster.Membership.subscribe()

receive do
  {:cluster_event, %NodeJoined{node_id: id}} ->
    IO.puts("Node #{id.value} joined")

  {:cluster_event, %NodeLeft{node_id: id, reason: reason}} ->
    IO.puts("Node #{id.value} left: #{reason}")

  {:cluster_event, %NodeDetectedDown{node_id: id}} ->
    IO.puts("Node #{id.value} is down")
end
```

**Lifecycle:** Subscription is automatically cleaned up when subscriber process dies.

---

#### unsubscribe/0

Unsubscribes from cluster membership events.

**Signature:**
```elixir
@spec unsubscribe() :: :ok
```

---

### Cluster.Heartbeat

Manages heartbeat-based failure detection.

#### get_last_heartbeat/1

Gets the last heartbeat from a node.

**Signature:**
```elixir
@spec get_last_heartbeat(NodeId.t()) :: {:ok, Heartbeat.t()} | {:error, :not_found}
```

**Parameters:**
- `node_id` (NodeId.t()): Node ID

**Returns:**
- `{:ok, heartbeat}`: Heartbeat found
- `{:error, :not_found}`: No heartbeat from node

**Example:**
```elixir
node_id = NodeId.new("node-2")

case Cluster.Heartbeat.get_last_heartbeat(node_id) do
  {:ok, hb} ->
    age_ms = Cluster.ValueObjects.Heartbeat.age_ms(hb)
    IO.puts("Last heartbeat #{age_ms}ms ago")

  {:error, :not_found} ->
    IO.puts("No heartbeat from node")
end
```

---

#### all_heartbeats/0

Gets all tracked heartbeats.

**Signature:**
```elixir
@spec all_heartbeats() :: %{NodeId.t() => heartbeat_state()}
```

**Returns:**
- Map of node IDs to heartbeat states

**Example:**
```elixir
heartbeats = Cluster.Heartbeat.all_heartbeats()

Enum.each(heartbeats, fn {node_id, state} ->
  age = Cluster.ValueObjects.Heartbeat.age_ms(state.last_heartbeat)
  IO.puts("#{node_id.value}: #{age}ms ago")
end)
```

---

#### send_heartbeat/0 (Deprecated)

Manually sends a heartbeat.

**Signature:**
```elixir
@deprecated "Use automatic heartbeats instead. Will be removed in v2.0.0"
@spec send_heartbeat() :: :ok
```

**Status:** Deprecated, will be removed in v2.0.0

**Replacement:** Heartbeats are automatic, no manual action needed.

---

## Replication API

### Replication

Top-level replication API.

#### all_groups/0

Gets all replication groups.

**Signature:**
```elixir
@spec all_groups() :: [map()]
```

**Returns:**
- List of replication group states

**Example:**
```elixir
groups = Replication.all_groups()

Enum.each(groups, fn group ->
  IO.puts("""
  Follower: #{group.follower}
  Leader offset: #{group.leader_offset}
  Follower offset: #{group.follower_offset}
  Lag: #{group.lag}
  Status: #{group.status}
  """)
end)
```

**Group format:**
```elixir
%{
  follower: "node-2",
  leader_offset: 10000,
  follower_offset: 9950,
  lag: 50,
  status: :replicating,  # or :paused, :disconnected
  credit: 95
}
```

---

### Replication.Leader

Leader-side replication process.

#### start_link/1

Starts a replication leader.

**Signature:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

**Parameters:**
- `opts` (keyword):
  - `:follower_node_id` (NodeId.t(), required): Follower node
  - `:start_offset` (integer, default: 0): Starting LSN

**Returns:**
- `{:ok, pid}`: Leader started
- `{:error, reason}`: Failed to start

**Example:**
```elixir
{:ok, pid} = Replication.Leader.start_link(
  follower_node_id: NodeId.new("node-2"),
  start_offset: 0
)

# Replication begins automatically
```

**Lifecycle:** Supervised by Replication.Supervisor

---

### Replication.Follower

Follower-side replication process.

#### start_link/1

Starts a replication follower.

**Signature:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

**Parameters:**
- `opts` (keyword):
  - `:leader_node_id` (NodeId.t(), required): Leader node
  - `:start_offset` (integer, default: 0): Starting LSN

**Example:**
```elixir
{:ok, pid} = Replication.Follower.start_link(
  leader_node_id: NodeId.new("node-1"),
  start_offset: 0
)
```

---

## Admin API

HTTP API for monitoring and management.

### Base URL

```
http://<host>:<admin_port>/api/v1
```

Default admin port: `9090`

### GET /status

Get cluster status.

**Request:**
```bash
curl http://localhost:9090/api/v1/status
```

**Response:**
```json
{
  "cluster_state": "healthy",
  "nodes": [
    {
      "id": "node-1",
      "status": "up",
      "heartbeat_age_ms": 50
    },
    {
      "id": "node-2",
      "status": "up",
      "heartbeat_age_ms": 45
    }
  ],
  "local_node_id": "node-1"
}
```

---

### GET /nodes

List all cluster nodes.

**Request:**
```bash
curl http://localhost:9090/api/v1/nodes
```

**Response:**
```json
{
  "nodes": [
    {
      "id": "node-1",
      "host": "10.0.1.10",
      "port": 4000,
      "admin_port": 9090,
      "status": "up"
    },
    {
      "id": "node-2",
      "host": "10.0.1.11",
      "port": 4000,
      "admin_port": 9090,
      "status": "up"
    }
  ]
}
```

---

### GET /replicas

Get replication status.

**Request:**
```bash
curl http://localhost:9090/api/v1/replicas
```

**Response:**
```json
{
  "replicas": [
    {
      "follower": "node-2",
      "leader_offset": 10000,
      "follower_offset": 9950,
      "lag": 50,
      "status": "replicating"
    }
  ]
}
```

---

## CLI Commands

### shanghaictl status

Show cluster status.

**Usage:**
```bash
shanghaictl status [options]
```

**Options:**
- `--host <host>`: Admin API host (default: localhost)
- `--port <port>`: Admin API port (default: 9090)
- `--format <format>`: Output format (text|json, default: text)

**Example:**
```bash
$ shanghaictl status

Shanghai Cluster Status
========================================

Cluster State: Healthy

Nodes:
  ✓ node-1 - up (heartbeat: 50ms ago)
  ✓ node-2 - up (heartbeat: 45ms ago)
  ✓ node-3 - up (heartbeat: 60ms ago)
```

**JSON output:**
```bash
$ shanghaictl status --format json
{"cluster_state":"healthy","nodes":[...]}
```

---

### shanghaictl node join

Join a node to the cluster.

**Usage:**
```bash
shanghaictl node join <node-id> --host=<host> --port=<port>
```

**Arguments:**
- `<node-id>`: Unique node identifier

**Options:**
- `--host <host>`: Node hostname or IP
- `--port <port>`: Node port
- `--admin-port <port>`: Admin API port (optional)

**Example:**
```bash
shanghaictl node join node-2 --host=10.0.1.11 --port=4000
```

---

### shanghaictl node leave

Remove a node from the cluster.

**Usage:**
```bash
shanghaictl node leave <node-id>
```

**Example:**
```bash
shanghaictl node leave node-2
```

---

### shanghaictl replicas

Show replication status.

**Usage:**
```bash
shanghaictl replicas [options]
```

**Example:**
```bash
$ shanghaictl replicas

Replication Status
========================================

node-1 → node-2:
  Leader offset:   10000
  Follower offset: 9950
  Lag:             50 offsets
  Status:          replicating
```

---

## Error Handling

### Common Error Types

| Error | Description | Resolution |
|-------|-------------|------------|
| `:disk_full` | Insufficient disk space | Free up space or add storage |
| `:not_found` | Resource doesn't exist | Check ID, ensure resource created |
| `:already_member` | Node already in cluster | No action needed |
| `:timeout` | Operation timed out | Check network, increase timeout |
| `:disconnected` | Node unreachable | Check network connectivity |

### Error Response Format (Admin API)

**HTTP Status Codes:**
- `200 OK`: Success
- `400 Bad Request`: Invalid input
- `404 Not Found`: Resource not found
- `500 Internal Server Error`: Server error

**Error Response:**
```json
{
  "error": {
    "code": "disk_full",
    "message": "Insufficient disk space",
    "details": {
      "available_bytes": 1024000,
      "required_bytes": 10240000
    }
  }
}
```

### Elixir Error Handling Patterns

**Pattern 1: Case statement**
```elixir
case Storage.WAL.Writer.append(data) do
  {:ok, lsn} ->
    handle_success(lsn)

  {:error, :disk_full} ->
    handle_disk_full()

  {:error, reason} ->
    handle_generic_error(reason)
end
```

**Pattern 2: With statement**
```elixir
with {:ok, lsn} <- Storage.WAL.Writer.append(data),
     {:ok, _} <- Replication.replicate(lsn) do
  {:ok, lsn}
else
  {:error, reason} -> {:error, reason}
end
```

**Pattern 3: Bang functions**
```elixir
try do
  lsn = Storage.WAL.Writer.append!(data)
  handle_success(lsn)
rescue
  e in RuntimeError ->
    handle_error(e)
end
```

## Type Specifications

### Common Types

```elixir
@type lsn :: non_neg_integer()
@type node_id :: String.t()
@type offset :: non_neg_integer()

# NodeId value object
%CoreDomain.Types.NodeId{value: String.t()}

# Node entity
%Cluster.Entities.Node{
  id: NodeId.t(),
  host: String.t(),
  port: integer(),
  admin_port: integer(),
  status: :up | :suspect | :down
}

# Heartbeat value object
%Cluster.ValueObjects.Heartbeat{
  node_id: NodeId.t(),
  timestamp: integer(),
  sequence: non_neg_integer()
}
```

## See Also

- [Getting Started Guide](GETTING_STARTED.md)
- [Architecture](ARCHITECTURE.md)
- [Protocol Specifications](protocols/)
- [Source Code](../apps/)
