# Shanghai

> The philosophy of this project is focused on creating a high-performance solution
> for distributed data storage and database interactions.

A distributed, replicated log storage system built on the Erlang VM (BEAM) using Elixir.

Shanghai provides:
- **Durable Write-Ahead Log (WAL)** with batched writes for high throughput
- **Multi-master replication** with credit-based flow control
- **Cluster membership** with heartbeat-based failure detection
- **Built-in observability** via telemetry and structured logging
- **Production-ready operations** with comprehensive tooling

**Measured:** ~10,600 writes/sec peak, P99 write latency 3.2 ms, on one NVMe
SSD. Eventual consistency.

> The original targets were 250,000+ writes/sec and <2 ms P99; both are missed,
> and the reason is fsync. At ~1.15 ms per flush this disk allows ~870
> fsyncs/sec, and group commit can only amortize that across concurrent
> writers - it reaches ~10.6k/sec but cannot go further without a cheaper
> durability path. Measure on your own hardware: every number here is
> storage-bound. See [Performance](docs/PERFORMANCE.md).

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

Shanghai consists of five main subsystems:

### 1. Storage (WAL)

Durable, sequential write-ahead log with batching support.

- **Segment-based** file layout (64 MB per segment)
- **Group commit** so concurrent writes share a single fsync
- **CRC32 checksums** for corruption detection
- **Segment compaction** merges rotated segments; no entry is ever discarded

**Throughput:** ~10,600 writes/sec measured (100 concurrent writers, NVMe)
**Latency:** P99 3.2ms measured (single writer)

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

### 4. Query (Key/Value API)

The primary user-facing interface, a durable, WAL-backed key/value store.

- **Rich operations**: reads/writes, conditional writes (`put_new`, `replace`,
  `cas`, `delete_if`), atomic counters, `get_and_update`, bulk `mset`/`mget`/
  `mdelete`, `rename`/`copy`/`swap`, and prefix `scan`/`count_prefix`
- **Read-through cache** with TTL, bounded eviction, and hit-ratio metrics
- **Crash recovery** by replaying the WAL on start-up
- **Observable by default**, every operation emits telemetry

**See:** [Query README](apps/query/README.md)

### 5. Observability

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

## Contributing

This is currently a learning/research project. Contributions welcome as the
project matures. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development
workflow, quality gates, and testing conventions.
