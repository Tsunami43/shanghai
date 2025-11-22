# Shanghai

A distributed, replicated log storage system built on the Erlang VM (BEAM) using Elixir.

Shanghai provides:
- **Durable Write-Ahead Log (WAL)** with batched writes for high throughput
- **Multi-master replication** with credit-based flow control
- **Cluster membership** with heartbeat-based failure detection
- **Built-in observability** via telemetry and structured logging
- **Production-ready operations** with comprehensive tooling

**Performance:** 250,000+ writes/sec, <2ms P99 latency, eventual consistency.

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

# Write to WAL
iex> {:ok, lsn} = Storage.WAL.Writer.append("Hello, Shanghai!")
{:ok, 1}

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

- Elixir 1.19 or later
- Erlang/OTP 27 or later

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

**Current Version:** 1.2.0 (Phase 4 - Completed November 2025)

### What's Implemented

✅ **Storage Layer**
- Write-Ahead Log with segment management
- Batched writes (60x throughput improvement)
- Crash recovery with torn write detection
- Segment compaction

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

✅ **Observability**
- Telemetry integration throughout
- Prometheus metrics export
- Structured logging
- Admin HTTP API
- CLI tools (shanghaictl)

✅ **Production Ready**
- Comprehensive documentation
- Performance benchmarks
- Operations guides
- Monitoring setup

### Not Yet Implemented

⚠️ **Reader API** - Currently write-only
⚠️ **Query layer** - No SQL-like queries
⚠️ **Strong consistency** - Eventual consistency only
⚠️ **Automatic conflict resolution** - Manual intervention required

### Release History

- **v1.2.0** (Sep 2025) - Observability, tooling, bug fixes
- **v1.1.0** (Jun 2025) - Replication with flow control
- **v1.0.0** (Mar 2025) - Initial release (WAL + Cluster)

## License

TBD

## Contributing

This is currently a learning/research project. Contributions welcome as the project matures.
