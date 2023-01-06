# Shanghai

A distributed, fault-tolerant database built on the BEAM virtual machine using Elixir.

Shanghai is designed as a long-term engineering project focusing on:
- Extreme availability and resilience
- Predictable behavior under partial failure
- Clear and explicit domain modeling
- Operational simplicity in distributed environments

The project prioritizes **correctness, transparency, and evolvability** over premature optimization.

## Architecture

Shanghai is built as an umbrella application with 6 bounded contexts, following Domain-Driven Design principles:

### Core Applications

#### 1. **core_domain** (Foundation Layer)
Shared domain models, types, protocols, and behaviors. No dependencies.

- Types: LogSequenceNumber, NodeId, Timestamp, Version
- Events: Event protocol, DomainEvent, EventMetadata
- Entities: LogEntry, AggregateRoot
- Value Objects: ConsistencyLevel, ReplicationMode, NodeState
- Protocols: Serializable, Validatable, Identifiable

#### 2. **storage** (Infrastructure Layer)
Local persistence, write-ahead log (WAL), compaction, snapshot management.

- WAL Writer/Reader for durable log storage
- Compaction process for space reclamation
- Snapshot Manager for point-in-time recovery
- LSM tree index for efficient reads

#### 3. **cluster** (Infrastructure Layer)
Node membership, discovery, health monitoring, failure detection.

- Membership Registry with SWIM-style gossip protocol
- Pluggable discovery strategies (DNS, static)
- Health monitoring with configurable probes
- Phi Accrual failure detector

#### 4. **replication** (Service Layer)
Log shipping, event propagation, conflict resolution.

- Log shipping for replica synchronization
- Event-based propagation with pub/sub
- Vector clock-based conflict detection
- Pluggable conflict resolution strategies
- Quorum-based consistency coordination

#### 5. **query** (Service Layer)
Public read/write API, query execution, consistency guarantees.

- `Query.read/2`, `Query.write/3`, `Query.transact/1` API
- Configurable consistency levels (:strong, :eventual, :causal)
- Query routing and load balancing
- Read repair and hinted handoff
- Transaction coordination

#### 6. **admin** (Cross-Cutting Layer)
Configuration, observability, metrics, operational tooling.

- Dynamic configuration management
- Metrics collection with Telemetry integration
- Distributed tracing support
- Health check aggregation
- Web-based monitoring dashboard

### Dependency Graph

```
core_domain (foundation - no deps)
    ↑
    ├── storage
    ├── cluster
    │
    ├── replication (deps: core_domain, storage, cluster)
    │
    ├── query (deps: core_domain, storage, cluster, replication)
    │
    └── admin (deps: all other apps)
```

## Design Principles

1. **Distribution is explicit** - No hidden magic. Replication, consistency, and coordination are modeled explicitly.

2. **DDD first** - All logic flows from domain concepts, not infrastructure concerns.

3. **OTP-native** - Supervisors, GenServers, and message passing are core building blocks, not implementation details.

4. **Failure is normal** - Node crashes, network partitions, and restarts are expected and handled.

5. **Evolvable over time** - Early decisions are allowed to be imperfect but must be replaceable.

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

This is Phase 0 (Jan-Feb 2023) - **Architectural Foundations**

The project currently has:
- Clear written vision
- Agreed architectural principles
- Initial repository scaffold with 6 bounded context apps
- Placeholder modules with TODOs for future implementation

**Not yet implemented:**
- Actual persistence (in-memory stubs only)
- Network protocols for distributed communication
- Consensus mechanisms
- Production-grade compaction algorithms
- Query language parser
- Dashboard frontend

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed architectural decisions and supervision tree hierarchies.

## Future Phases

- **Phase 1** (Mar-Jun 2023): Local Storage & Persistence Foundations
- **Phase 2**: Cluster Formation & Membership
- **Phase 3**: Replication & Consistency
- **Phase 4**: Query Layer & Transactions
- **Phase 5**: Observability & Operations

## License

TBD

## Contributing

This is currently a learning/research project. Contributions welcome as the project matures.
