# Getting Started with Shanghai

This guide will help you get up and running with Shanghai, from installation to building your first distributed application.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Concepts](#basic-concepts)
- [Your First Application](#your-first-application)
- [Working with the WAL](#working-with-the-wal)
- [Setting Up a Cluster](#setting-up-a-cluster)
- [Monitoring and Observability](#monitoring-and-observability)
- [Next Steps](#next-steps)

## Prerequisites

Before you begin, ensure you have:

- **Erlang/OTP 26+**: `erl -version`
- **Elixir 1.16+**: `elixir --version` (the umbrella apps require `~> 1.16`)
- **Git**: `git --version`
- **Basic Elixir knowledge**: Understanding of GenServers, supervision trees

### Installing Erlang and Elixir

**On Ubuntu/Debian:**
```bash
# Add Erlang Solutions repository
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update

# Install Erlang and Elixir
sudo apt-get install erlang-base erlang-dev elixir
```

**On macOS:**
```bash
brew install erlang elixir
```

**Verify installation:**
```bash
$ erl -version
Erlang (SMP,ASYNC_THREADS) (BEAM) emulator version 14.0

$ elixir --version
Elixir 1.16.3 (compiled with Erlang/OTP 26)
```

## Installation

### Clone the Repository

```bash
git clone https://github.com/Tsunami43/shanghai.git
cd shanghai
```

### Install Dependencies

```bash
mix deps.get
mix compile
```

### Run Tests

```bash
mix test
```

You should see all tests passing:

```
...................................
Finished in 2.5 seconds (async: true, load: 0.1s)
120 tests, 0 failures
```

### Build a Release

```bash
mix release
```

The release will be in `_build/dev/rel/shanghai/`.

## Quick Start

### Start Shanghai in Development Mode

```bash
# Start an interactive shell
iex -S mix

# Shanghai should start automatically
iex(1)> Cluster.Membership.local_node_id()
%CoreDomain.Types.NodeId{value: "nonode@nohost"}
```

### Write and Read with the Query API

The `Query` module is the recommended user-facing key/value API. It works out of
the box (in-memory) and becomes durable once storage is configured with a
`data_root`.

```elixir
# Write a value
iex(2)> Query.write("greeting", "Hello, Shanghai!")
{:ok, :written}

# Read it back
iex(3)> Query.read("greeting")
{:ok, "Hello, Shanghai!"}

# A missing key
iex(4)> Query.read("nope")
{:error, :not_found}

# Atomic counter
iex(5)> Query.increment("visits")
{:ok, 1}
```

See [Examples](EXAMPLES.md#keyvalue-store-query-api) for transactions,
compare-and-swap, and range scans.

### Lower-level: the Write-Ahead Log

The Query layer is backed by a segment-based Write-Ahead Log. When storage is
configured with a `data_root`, `Storage.WAL.Writer.append/1` and
`Storage.WAL.Reader.read/1` are available directly; see
[Working with the WAL](#working-with-the-wal).

## Basic Concepts

### Log Sequence Number (LSN)

Every entry in the WAL gets a unique, monotonically increasing **LSN**:

```
Entry 1: LSN = 1
Entry 2: LSN = 2
Entry 3: LSN = 3
...
```

LSNs are used for:
- Ordering entries
- Replication (tracking follower progress)
- Point-in-time recovery

### Node ID

Each Shanghai node has a unique **Node ID**:

```elixir
node_id = Cluster.Membership.local_node_id()
#=> %NodeId{value: "node-1"}
```

Node IDs are used for:
- Cluster membership
- Identifying replication sources/targets
- Routing requests

### Cluster State

The cluster maintains a view of all member nodes:

```elixir
nodes = Cluster.Membership.all_nodes()
#=> [
#  %Node{id: %NodeId{value: "node-1"}, status: :up, ...},
#  %Node{id: %NodeId{value: "node-2"}, status: :up, ...}
#]
```

## Your First Application

Let's build a simple distributed counter using Shanghai.

### Step 1: Define the Application

Create `lib/counter_app.ex`:

```elixir
defmodule CounterApp do
  @moduledoc """
  A distributed counter built on Shanghai.
  """

  use GenServer
  require Logger

  alias Storage.WAL.Writer
  alias CoreDomain.Types.NodeId

  @type state :: %{
    count: integer(),
    node_id: NodeId.t()
  }

  ## Client API

  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increments the counter and persists to WAL"
  def increment do
    GenServer.call(__MODULE__, :increment)
  end

  @doc "Gets the current count"
  def get do
    GenServer.call(__MODULE__, :get)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    node_id = Cluster.Membership.local_node_id()

    state = %{
      count: 0,
      node_id: node_id
    }

    Logger.info("CounterApp started on node #{node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_call(:increment, _from, state) do
    new_count = state.count + 1

    # Persist increment to WAL
    event = %{
      type: :increment,
      node_id: state.node_id.value,
      timestamp: System.system_time(:millisecond)
    }
    encoded = :erlang.term_to_binary(event)

    case Writer.append(encoded) do
      {:ok, lsn} ->
        Logger.debug("Persisted increment at LSN #{lsn}")
        {:reply, {:ok, new_count}, %{state | count: new_count}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.count, state}
  end
end
```

### Step 2: Add to Supervision Tree

Edit `lib/shanghai.ex`:

```elixir
defmodule Shanghai do
  use Application

  def start(_type, _args) do
    children = [
      # ... existing children ...
      CounterApp  # Add this line
    ]

    opts = [strategy: :one_for_one, name: Shanghai.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Step 3: Try It Out

```bash
iex -S mix
```

```elixir
# Increment the counter
iex(1)> CounterApp.increment()
{:ok, 1}

iex(2)> CounterApp.increment()
{:ok, 2}

# Get current count
iex(3)> CounterApp.get()
2
```

The counter increments are now persisted in the WAL!

## Working with the WAL

### Appending Data

```elixir
# Simple append
{:ok, lsn} = Storage.WAL.Writer.append("my data")

# Append with error handling
case Storage.WAL.Writer.append(data) do
  {:ok, lsn} ->
    Logger.info("Written at LSN #{lsn}")

  {:error, :disk_full} ->
    Logger.error("Out of disk space!")

  {:error, reason} ->
    Logger.error("Write failed: #{inspect(reason)}")
end
```

### Batched Writes (High Throughput)

Batching is automatic - the WAL writer group-commits, so nothing extra is
needed for high throughput workloads:

```elixir
# Concurrent appends share a single fsync; each caller still blocks until
# its own entry is durable.
{:ok, lsn} = Storage.append(data)
```

**When to use batching:**
- High write volume (>1000 writes/sec)
- Acceptable to trade latency for throughput
- Multiple concurrent writers

**When NOT to use batching:**
- Low latency required (<1ms)
- Low write volume
- Single-threaded writes

### Configuring WAL Behavior

In `config/config.exs`:

```elixir
config :storage,
  # Root directory for WAL segments, index and snapshots. When set, the full
  # durable stack starts; when absent, storage runs in minimal (in-memory) mode.
  data_root: "/var/lib/shanghai/data",

  # Node identifier stamped on log entries.
  node_id: "node1",

  # Rotate to a new segment at this size or age.
  segment_size_threshold: 64 * 1024 * 1024,
  segment_time_threshold: 3600,

  # Snapshot retention and background compaction.
  snapshot_retention: 5,
  compaction_interval: 3_600_000,
  compaction_enabled: true
```

> Each WAL append is fsynced today, so durability is not yet tunable via config.
> Configurable fsync modes, compression, and the batch-writer settings are on the
> roadmap.

## Setting Up a Cluster

### 3-Node Cluster Setup

Let's set up a 3-node cluster on one machine using different ports.

#### Node 1

```bash
# Terminal 1
export SHANGHAI_NODE_ID="node-1"
export SHANGHAI_PORT="4001"
export SHANGHAI_ADMIN_PORT="9091"
export SHANGHAI_DATA_DIR="/tmp/shanghai/node1"

iex --name node1@127.0.0.1 --cookie shanghai -S mix
```

#### Node 2

```bash
# Terminal 2
export SHANGHAI_NODE_ID="node-2"
export SHANGHAI_PORT="4002"
export SHANGHAI_ADMIN_PORT="9092"
export SHANGHAI_DATA_DIR="/tmp/shanghai/node2"

iex --name node2@127.0.0.1 --cookie shanghai -S mix
```

#### Node 3

```bash
# Terminal 3
export SHANGHAI_NODE_ID="node-3"
export SHANGHAI_PORT="4003"
export SHANGHAI_ADMIN_PORT="9093"
export SHANGHAI_DATA_DIR="/tmp/shanghai/node3"

iex --name node3@127.0.0.1 --cookie shanghai -S mix
```

### Join Nodes to Cluster

From node1:

```elixir
# Connect Erlang nodes
iex(node1)> Node.connect(:"node2@127.0.0.1")
true

iex(node1)> Node.connect(:"node3@127.0.0.1")
true

# Join nodes to Shanghai cluster
alias Cluster.Entities.Node
alias CoreDomain.Types.NodeId

node2 = Node.new(
  node_id: NodeId.new("node-2"),
  host: "127.0.0.1",
  port: 4002
)

Cluster.Membership.join_node(node2)
#=> :ok

node3 = Node.new(
  node_id: NodeId.new("node-3"),
  host: "127.0.0.1",
  port: 4003
)

Cluster.Membership.join_node(node3)
#=> :ok
```

### Verify Cluster

```elixir
iex(node1)> Cluster.Membership.all_nodes()
[
  %Node{id: %NodeId{value: "node-1"}, status: :up, ...},
  %Node{id: %NodeId{value: "node-2"}, status: :up, ...},
  %Node{id: %NodeId{value: "node-3"}, status: :up, ...}
]
```

### Set Up Replication

Start replication from node1 to node2:

```elixir
iex(node1)> {:ok, pid} = Replication.Leader.start_link(
  follower_node_id: NodeId.new("node-2"),
  start_offset: 0
)
{:ok, #PID<0.234.0>}

# Check replication status
iex(node1)> Replication.all_groups()
[
  %{
    follower: "node-2",
    leader_offset: 0,
    follower_offset: 0,
    lag: 0,
    status: :replicating
  }
]
```

Now writes on node1 will replicate to node2!

## Monitoring and Observability

### Using the Admin API

Shanghai exposes metrics via HTTP:

```bash
# Check cluster status
curl http://localhost:9091/api/v1/status | jq
{
  "cluster_state": "healthy",
  "nodes": [
    {"id": "node-1", "status": "up", "heartbeat_age_ms": 50},
    {"id": "node-2", "status": "up", "heartbeat_age_ms": 45}
  ]
}

# Check replication status
curl http://localhost:9091/api/v1/replicas | jq
{
  "replicas": [
    {
      "follower": "node-2",
      "lag": 10,
      "status": "replicating"
    }
  ]
}
```

### Attaching Telemetry Handlers

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def attach do
    events = [
      [:shanghai, :wal, :write, :completed],
      [:shanghai, :cluster, :heartbeat, :completed],
      [:shanghai, :replication, :lag, :changed]
    ]

    :telemetry.attach_many(
      "my-app-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:shanghai, :wal, :write, :completed], measurements, metadata, _config) do
    Logger.info("WAL write completed",
      duration: measurements.duration,
      bytes: measurements.bytes,
      segment: metadata.segment_id
    )
  end

  def handle_event([:shanghai, :cluster, :heartbeat, :completed], measurements, _metadata, _config) do
    if measurements.rtt > 100 do
      Logger.warning("Slow heartbeat: #{measurements.rtt}ms")
    end
  end

  def handle_event([:shanghai, :replication, :lag, :changed], measurements, metadata, _config) do
    if measurements.lag > 10_000 do
      Logger.error("High replication lag: #{measurements.lag} offsets",
        follower: metadata.follower
      )
    end
  end
end

# Attach in your application start
MyApp.Telemetry.attach()
```

### Prometheus Integration

Export metrics to Prometheus:

```elixir
# In config/config.exs
config :shanghai,
  telemetry_prometheus_port: 9568
```

Metrics available at `http://localhost:9568/metrics`:

```
# HELP shanghai_wal_write_duration_ms WAL write duration
# TYPE shanghai_wal_write_duration_ms histogram
shanghai_wal_write_duration_ms_bucket{le="1"} 850
shanghai_wal_write_duration_ms_bucket{le="5"} 990
shanghai_wal_write_duration_ms_bucket{le="10"} 998
shanghai_wal_write_duration_ms_bucket{le="+Inf"} 1000
shanghai_wal_write_duration_ms_sum 2450
shanghai_wal_write_duration_ms_count 1000
```

## Next Steps

Now that you've got the basics, explore:

1. **[Architecture Guide](ARCHITECTURE.md)** - Understand Shanghai's internals
2. **[API Reference](API.md)** - Complete API documentation
3. **[Performance Tuning](TUNING.md)** - Optimize for your workload
4. **[Operations Guide](OPERATIONS.md)** - Production deployment
5. **[Protocol Specifications](PROTOCOLS.md)** - Wire protocol details

### Example Applications

Check out these examples:

- **Distributed Counter** (above)
- **Event Sourcing**: Store domain events in WAL
- **Message Queue**: Use WAL as a durable queue
- **Changelog Synchronization**: Replicate data changes

### Community

- GitHub Issues: https://github.com/Tsunami43/shanghai/issues
- Slack: #shanghai-users
- Documentation: https://shanghai.readthedocs.io/

Happy hacking with Shanghai!
