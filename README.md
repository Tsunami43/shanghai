# Shanghai

> The philosophy of this project is focused on creating a high-performance solution
> for distributed data storage and database interactions.
> — Tsunami43

A distributed, replicated log storage system built on the Erlang VM (BEAM) using Elixir.

Shanghai provides:
- **Durable Write-Ahead Log (WAL)** with batched writes for high throughput
- **Multi-master replication** with credit-based flow control
- **Cluster membership** with heartbeat-based failure detection
- **Built-in observability** via telemetry and structured logging
- **Production-ready operations** with comprehensive tooling

**Performance targets:** 250,000+ writes/sec, <2ms P99 latency, eventual consistency.

> The throughput target assumes batched writes; the batch writer is not yet wired
> into the default path (writes fsync per append today), so single-node
> throughput is currently lower. Measured P99 write latency is well within the
> <2ms target. See [Performance](docs/PERFORMANCE.md).

The project prioritizes **simplicity, observability, and operational excellence** over complexity.

## Quick Start

```bash
# Install dependencies
mix deps.get
mix compile

# Run tests
mix test

# Start Shanghai
iex -S mix

# Key/value operations via the Query API (durable, WAL-backed)
iex> Query.write("user:1", %{name: "Alice"})
{:ok, :written}
iex> Query.read("user:1")
{:ok, %{name: "Alice"}}

# Append directly to the WAL (LSNs start at 0)
iex> {:ok, lsn} = Storage.append("Hello, Shanghai!")
{:ok, 0}

# Check cluster status
iex> Cluster.Membership.all_nodes()
[%Cluster.Entities.Node{...}]
```

## Architecture

Shanghai consists of four main subsystems:

### 1. Storage (WAL)

Durable, sequential write-ahead log with batching support.

- **Segment-based** file layout (64 MB per segment)
- **Batched writes** for 60x throughput improvement
- **CRC32 checksums** for corruption detection
- **Automatic compaction** of old segments

**Throughput:** 250,000+ writes/sec (batched)
**Latency:** P99 < 2ms

### 2. Cluster Membership

Distributed membership management with failure detection.

- **Heartbeat protocol** (5-second intervals)
- **Failure detection** (suspect at 10s, down at 15s)
- **Gossip dissemination** for state propagation
- **Event notifications** for membership changes

**Detection time:** ~10-15 seconds
**Scales to:** 100+ nodes

### 3. Replication

Asynchronous multi-master replication with backpressure.

- **Credit-based flow control** prevents memory exhaustion
- **Batch transmission** for efficiency
- **Automatic recovery** from failures
- **Lag monitoring** via telemetry

**Throughput:** 50,000+ entries/sec (LAN)
**Lag:** <100ms under normal load

### 4. Observability

Built-in metrics, logging, and monitoring.

- **Telemetry events** for all operations
- **Structured logging** with correlation IDs
- **Prometheus metrics** export
- **Admin HTTP API** for status

**See:** [Observability Guide](docs/OBSERVABILITY.md)

## Documentation

### Getting Started

- **[Getting Started Guide](docs/GETTING_STARTED.md)** - Installation, first app, cluster setup
- **[Examples](docs/EXAMPLES.md)** - Event sourcing, counters, queues, and more
- **[Integration Guide](docs/INTEGRATION.md)** - Embed Shanghai in your application

### Architecture & Protocols

- **[Architecture Overview](docs/ARCHITECTURE.md)** - System design and components
- **[WAL Protocol](docs/protocols/WAL_PROTOCOL.md)** - File format specification
- **[Replication Protocol](docs/protocols/REPLICATION_PROTOCOL.md)** - Replication mechanics
- **[Cluster Protocol](docs/protocols/CLUSTER_PROTOCOL.md)** - Membership and failure detection

### Operations

- **[Operations Guide](docs/OPERATIONS.md)** - Production deployment and maintenance
- **[Performance Guide](docs/PERFORMANCE.md)** - Benchmarks and optimization
- **[Tuning Guide](docs/TUNING.md)** - Configuration recommendations
- **[Observability Guide](docs/OBSERVABILITY.md)** - Monitoring and debugging

### Reference

- **[API Reference](docs/API.md)** - Complete API documentation
- **[Deprecations](docs/DEPRECATIONS.md)** - Deprecated features and migration
- **[ADRs](docs/adr/)** - Architecture decision records

## Design Principles

1. **Simplicity over complexity** - Choose simple, understandable designs
2. **Fail-fast philosophy** - Crash and restart rather than inconsistent state
3. **Observable by default** - Everything emits telemetry
4. **Location transparency** - Distributed operations look like local ones

## Development

### Prerequisites

- Elixir 1.16 or later (umbrella apps require `~> 1.16`)
- Erlang/OTP 26 or later (CI runs on OTP 26.2)

### Setup

```bash
# Clone the repository
git clone <repository-url>
cd shanghai

# Get dependencies
mix deps.get

# Compile all apps
mix compile

# Run tests
mix test

# Format code
mix format

# Run quality checks
mix quality
```

### Running the Database

```bash
# Start an interactive shell
iex -S mix

# Basic operations
iex> Query.write("user:1", %{name: "Alice", email: "alice@example.com"})
{:ok, :written}

iex> Query.read("user:1")
{:ok, %{name: "Alice", email: "alice@example.com"}}

iex> Query.delete("user:1")
{:ok, :deleted}
```

## Project Status

### What's Implemented

✅ **Storage Layer**
- Write-Ahead Log with segment management
- Crash recovery with torn write detection
- Segment compaction (segment selection; merge/reclaim on the roadmap)

🚧 **Storage (in progress)**
- Batch writer component (not yet wired into the default write path)

✅ **Cluster Management**
- Heartbeat-based failure detection
- Membership state management
- Event notification system
- Erlang distribution integration

✅ **Replication**
- Leader-follower replication
- Credit-based flow control
- Automatic backpressure
- Lag monitoring

✅ **Query Layer**
- `read`/`write`/`delete`/`transact` over a WAL-backed KV store
- Crash recovery by WAL replay on startup
- Read-through cache with consistent invalidation
- `scan`/`keys`/`count` collection access

✅ **Observability**
- Telemetry integration throughout (incl. `[:shanghai, :query, :operation]`)
- Structured logging
- Admin HTTP API (`/api/v1/status|nodes|replicas|metrics`)
- CLI tools (shanghaictl)

### Current scope & roadmap

Shanghai runs **single-node today**: storage/WAL and the query layer are
durable and real, while cluster membership and replication currently operate as
in-node coordination. The path to a fully distributed v1.0 — networked
replication with quorums and anti-entropy, sharding, consensus, a wire protocol,
security and deployment — is tracked commit-by-commit in
[`docs/ROADMAP_1000.md`](docs/ROADMAP_1000.md) and
[`docs/COMMIT_PLAN.md`](docs/COMMIT_PLAN.md). Items marked ✅ above are
implemented at single-node scope; Prometheus export and gRPC remain on the
roadmap.

## Contributing

This is currently a learning/research project. Contributions welcome as the
project matures. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development
workflow, quality gates, and testing conventions.
