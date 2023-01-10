# Shanghai Architecture

This document describes the architectural decisions, bounded contexts, and technical design of the Shanghai distributed database.

## Table of Contents

- [Overview](#overview)
- [Bounded Contexts](#bounded-contexts)
- [Supervision Trees](#supervision-trees)
- [Communication Patterns](#communication-patterns)
- [Design Decisions](#design-decisions)

## Overview

Shanghai follows a **Domain-Driven Design** approach with clear bounded contexts implemented as separate OTP applications within an umbrella project. Each bounded context has:

- Clear responsibility and domain focus
- Explicit dependencies on other contexts
- Own supervision tree (except core_domain)
- Independent failure domain

## Bounded Contexts

### 1. Core Domain (Foundation)

**Type:** Library (no processes)
**Dependencies:** None
**Purpose:** Shared domain language

**Key Abstractions:**

- `LogSequenceNumber` - Total ordering of events
- `NodeId` - Node identification in cluster
- `ConsistencyLevel` - Consistency semantics
- `LogEntry` - Immutable log entry entity
- `Event` protocol - Domain event contract

**Design Rationale:**

Core domain is a pure library with no side effects. It defines the ubiquitous language used across all bounded contexts. By having zero dependencies, it serves as a stable foundation that other contexts build upon.

### 2. Storage (Infrastructure)

**Type:** Application with supervision tree
**Dependencies:** core_domain
**Purpose:** Local persistence and durability

**Key Components:**

- **WAL Writer** - Append-only log with fsync guarantees
- **WAL Reader** - Random and sequential log access
- **Compaction** - Background merge and space reclamation
- **Snapshot Manager** - Point-in-time backups

**Supervision Tree:**

```
Storage.Supervisor (one_for_one)
├── Storage.WAL.Writer
├── Storage.WAL.Reader
├── Storage.Compaction.Compactor
└── Storage.Snapshot.Manager
```

**Design Rationale:**

The storage layer is kept simple and local. It doesn't know about distribution or replication - that's the replication context's job. WAL provides durability, compaction optimizes space, snapshots enable fast recovery.

### 3. Cluster (Infrastructure)

**Type:** Application with supervision tree
**Dependencies:** core_domain
**Purpose:** Membership and health management

**Key Components:**

- **Membership Registry** - Track cluster members
- **Gossip Protocol** - SWIM-inspired dissemination
- **Discovery Manager** - Find nodes (DNS, static, etc.)
- **Health Monitor** - Liveness and readiness checks
- **Failure Detector** - Phi Accrual detection

**Supervision Tree:**

```
Cluster.Supervisor (one_for_one)
├── Cluster.Membership.Registry
├── Cluster.Membership.Gossip
├── Cluster.Discovery.DiscoveryManager
├── Cluster.Health.Monitor
├── Cluster.FailureDetection.Detector
└── Cluster.FailureDetection.Heartbeat
```

**Design Rationale:**

Cluster management is explicit and observable. Gossip provides eventual consistency of membership. Phi Accrual failure detection adapts to network conditions. Health monitoring is pluggable.

### 4. Replication (Service)

**Type:** Application with supervision tree
**Dependencies:** core_domain, storage, cluster
**Purpose:** Data replication and conflict resolution

**Key Components:**

- **Log Shipper** - Send WAL to replicas
- **Log Receiver** - Receive and apply WAL
- **Conflict Detector** - Vector clock comparison
- **Consistency Coordinator** - Quorum operations
- **Sync Manager** - Full and incremental sync

**Supervision Tree:**

```
Replication.Supervisor (rest_for_one)
├── Replication.LogShipping.Receiver
├── Replication.LogShipping.Shipper
├── Replication.EventPropagation.Publisher
├── Replication.EventPropagation.Subscriber
├── Replication.Consistency.Coordinator
└── Replication.Sync.SyncManager
```

**Strategy:** `rest_for_one` because children have dependencies (receiver must start before shipper).

**Design Rationale:**

Replication is layered on top of local storage. Log shipping provides the mechanism, consistency coordination provides the semantics. Conflicts are detected and resolved explicitly, not hidden.

### 5. Query (Service)

**Type:** Application with supervision tree
**Dependencies:** core_domain, storage, cluster, replication
**Purpose:** User-facing read/write API

**Public API:**

- `Query.read(key, opts)` - Read with configurable consistency
- `Query.write(key, value, opts)` - Write with replication
- `Query.transact(operations)` - Multi-operation transactions
- `Query.delete(key, opts)` - Tombstone deletion

**Key Components:**

- **Query Executor** - Execute reads with consistency
- **Write Executor** - Coordinate writes and replication
- **Transaction Coordinator** - ACID transaction support
- **Query Cache** - Cache frequently accessed data
- **Router** - Route queries to appropriate nodes

**Supervision Tree:**

```
Query.Supervisor (one_for_one)
├── Query.Executor.QueryExecutor
├── Query.Executor.WriteExecutor
├── Query.Consistency.Coordinator
├── Query.Cache.QueryCache
├── Query.Transaction.Coordinator
└── Query.Routing.Router
```

**Design Rationale:**

The query layer is the composition point. It doesn't implement storage or replication - it orchestrates the lower layers to provide user-visible semantics. Consistency levels are explicit parameters, not hidden defaults.

### 6. Admin (Cross-Cutting)

**Type:** Application with supervision tree
**Dependencies:** All other apps
**Purpose:** Observability and operations

**Key Components:**

- **Config Manager** - Dynamic configuration
- **Metrics Collector** - Telemetry integration
- **Health Checker** - Aggregate system health
- **Dashboard Server** - Web-based monitoring

**Supervision Tree:**

```
Admin.Supervisor (one_for_one)
├── Admin.Config.Manager
├── Admin.Observability.Metrics.Collector
├── Admin.Observability.Tracing.Tracer
├── Admin.Health.Checker
└── Admin.Dashboard.Server
```

**Design Rationale:**

Admin observes all other contexts without them depending on it. Metrics are collected via Telemetry callbacks, not direct calls. Configuration can be hot-reloaded without restarts.

## Supervision Trees

### Strategy Selection

- **one_for_one** - Most common. One child failure doesn't affect others.
- **rest_for_one** - Used in replication where children have dependencies.
- **one_for_all** - Not used yet, reserved for tightly coupled processes.

### Failure Handling

Each bounded context's supervision tree provides fault isolation:

- Storage failure doesn't crash cluster membership
- Cluster changes don't crash ongoing queries
- Admin observability doesn't affect core operations

## Communication Patterns

### Synchronous (GenServer.call)

Used for:
- User-facing API calls (Query.read/write)
- Coordinated operations requiring acknowledgment
- Critical path operations

Example: `Query.write` → `Storage.WAL.Writer.append`

### Asynchronous (GenServer.cast, send)

Used for:
- Event propagation
- Background operations
- Non-critical notifications

Example: Gossip dissemination, health check updates

### Pub/Sub (Registry, Phoenix.PubSub)

Used for:
- Event-driven architecture
- Cluster-wide notifications
- Observability events

Example: Node join/leave events, metrics publishing

## Design Decisions

### Decision 1: Umbrella vs Monorepo

**Chosen:** Umbrella application

**Rationale:**
- Enforces bounded context separation
- Explicit dependencies via `in_umbrella: true`
- Shared build artifacts
- Easy to extract apps later if needed

**Alternatives Considered:**
- Monolithic application (rejected - hard to enforce boundaries)
- Separate repos (rejected - too much overhead for early stage)

### Decision 2: LSN-based Ordering

**Chosen:** Monotonic LogSequenceNumber for all entries

**Rationale:**
- Total ordering within a node
- Simple to reason about
- Efficient for replication (ship by LSN range)
- Foundation for consistency protocols

**Alternatives Considered:**
- Lamport clocks (rejected - need total order, not just partial)
- Hybrid logical clocks (deferred - may add later for cross-node ordering)

### Decision 3: CP vs AP

**Chosen:** CP-leaning with configurable consistency

**Rationale:**
- Writes favor consistency within quorum
- Reads can be tuned (local, quorum, leader)
- Network partitions are detected and surfaced
- Users choose consistency vs availability tradeoff

**Alternatives Considered:**
- Pure AP (rejected - too much conflict resolution complexity)
- Pure CP (rejected - limits availability during partitions)

### Decision 4: No Global Consensus (Phase 0)

**Chosen:** No Raft/Paxos in initial implementation

**Rationale:**
- Simplifies initial design
- Quorum-based consistency sufficient for early use cases
- Can add consensus later for specific features (e.g., schema changes)
- BEAM distribution provides foundation

**Alternatives Considered:**
- Raft from day one (rejected - premature complexity)

### Decision 5: Explicit Supervision Trees

**Chosen:** Custom supervisors in each app, not umbrella-level

**Rationale:**
- Clear ownership of processes
- Bounded context isolation
- Easier to understand failure domains
- Applications can start/stop independently

**Alternatives Considered:**
- Single umbrella supervisor (rejected - couples everything)

## Future Architectural Considerations

### Not Decided Yet

1. **Transaction Isolation Level**
   - Current: Basic optimistic concurrency control planned
   - Future: May need MVCC or snapshot isolation

2. **Network Protocol**
   - Current: Erlang distribution (:rpc)
   - Future: May need custom protocol (Protocol Buffers, MessagePack)

3. **Storage Engine**
   - Current: Simple WAL + in-memory
   - Future: LSM tree, B+ tree, or pluggable backends

4. **Query Language**
   - Current: Direct Elixir API
   - Future: SQL-like or custom query DSL

5. **Schema Management**
   - Current: Schemaless (maps)
   - Future: Optional schema with migrations

### Evolvability

The architecture is designed to evolve:

- Bounded contexts can be rewritten independently
- Protocols allow implementation swapping
- Supervision trees contain failure blast radius
- Dependencies are explicit and directed

Any major change should:
1. Update this document
2. Consider impact on dependent contexts
3. Maintain backward compatibility or version migrations
4. Add tests before and after changes

## References

- Phase 0 Vision Document
- Domain-Driven Design (Eric Evans)
- Designing Data-Intensive Applications (Martin Kleppmann)
- Making Reliable Distributed Systems in the Presence of Software Errors (Joe Armstrong)
