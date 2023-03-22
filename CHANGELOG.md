# Changelog

All notable changes to the Shanghai project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2025-11-22

### Phase 4: Operations & Observability

Complete operational tooling and comprehensive documentation suite.

### Added

**CLI & Admin API**
- CLI tool (`shanghaictl`) for cluster operations and monitoring
- HTTP Admin API with correlation IDs for request tracing
- Status, metrics, nodes, and replicas inspection commands
- Node join/leave management commands
- Cluster shutdown and replica management operations

**Observability & Monitoring**
- Comprehensive telemetry integration across Storage, Cluster, and Replication subsystems
- Structured logging with correlation tracking
- Prometheus metrics for operational visibility
- Request tracing infrastructure

**Documentation**
- Complete getting started guide with interactive examples
- Architecture guide and decision records (ADRs)
- Protocol specifications (WAL, Replication, Cluster Membership)
- Comprehensive API reference for all subsystems
- Application integration patterns (Event Sourcing, CDC, Audit Logging)
- Performance characteristics and tuning guide
- Observability and monitoring setup guide
- Code examples and tutorials
- Operations guide for production deployments

### Fixed
- Improved cluster subscriber lifecycle management

### Changed
- Added deprecation warnings for legacy APIs

### Performance
- Implemented WAL write batching module
- Added comprehensive storage benchmarking module

## [1.0.0] - 2024-09-15

### Phase 3: Replication & Consistency

Production-ready replication system with configurable consistency levels.

### Added

**Replication Engine**
- Leader-based write routing architecture
- Follower GenServer for consuming replication streams
- Stream GenServer for WAL replication
- Replica catch-up mechanism for lagging followers
- Replication monitoring and lag tracking
- Process registry for replica management
- Public API for managing replication groups

**Consistency & Quorum**
- ConsistencyLevel value object (ONE, QUORUM, ALL)
- Quorum-based write acknowledgment
- Quorum calculation utilities
- Consistency level validation

**Domain Model**
- ReplicationOffset value object for tracking replica positions
- Replica entity with state management
- ReplicaGroup aggregate for coordinating replicas
- Replication domain events

**Testing & Documentation**
- Leader-Follower integration tests
- Failure scenario test coverage
- Performance benchmarks for replication
- Replication protocol documentation
- Consistency level usage guide
- Replication app README and CHANGELOG

## [0.2.0] - 2023-12-28

### Phase 2: Cluster Membership & Node Discovery

Distributed cluster awareness with automatic node discovery and failure detection.

### Added

**Cluster Membership**
- Node join/leave protocol
- Cluster state aggregate for membership tracking
- Node entity with lifecycle management
- Heartbeat mechanism for node liveness detection
- Automatic node crash detection
- Process notification system for NodeUp/NodeDown events

**Gossip Protocol**
- Gossip-based cluster event propagation
- Membership change broadcasting
- Split-brain detection

**Domain Model**
- Domain events for membership changes (NodeJoined, NodeLeft, NodeFailed)
- Value objects for heartbeat and node metadata

**Infrastructure**
- OTP supervision tree for cluster processes
- Test environment configuration

**Testing & Documentation**
- Unit tests for Node and Cluster state
- Integration tests for gossip and membership
- Node crash simulation tests
- Cluster protocol documentation and event flow diagrams

## [0.1.0] - 2023-05-15

### Phase 1: Write-Ahead Log (WAL) Implementation

Foundation storage layer with durable WAL and segment management.

### Added

**Core WAL System**
- WAL Writer with automatic segment rotation
- WAL Reader with efficient LSN lookup
- Segment module with binary format specification
- SegmentManager for segment lifecycle management
- SegmentIndex with ETS-based LSN indexing

**Data Management**
- Serializer for entry encoding/decoding
- FileBackend for low-level I/O operations
- Snapshot system with compression and retention policies
- Compaction system with size-tiered strategy

**Infrastructure**
- Supervisor structure with comprehensive configuration
- Umbrella project structure with 6 bounded context apps:
  - Storage (WAL)
  - Cluster
  - Replication
  - Admin
  - CLI
  - Observability

**Project Setup**
- Initial Elixir project structure
- Conversion to umbrella architecture
- Build and dependency configuration

---

## Version History Summary

- **v1.2.0** (Nov 2025): Operations tooling, observability, and complete documentation
- **v1.0.0** (Sep 2024): Replication with quorum-based consistency
- **v0.2.0** (Dec 2023): Cluster membership and gossip protocol
- **v0.1.0** (May 2023): Write-Ahead Log foundation

## Links

- [Project README](README.md)
- [Architecture Guide](docs/architecture.md)
- [Getting Started](docs/getting-started.md)
- [Operations Guide](docs/operations.md)

[1.2.0]: https://github.com/yourusername/shanghai/compare/v1.0.0...v1.2.0
[1.0.0]: https://github.com/yourusername/shanghai/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/yourusername/shanghai/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/yourusername/shanghai/releases/tag/v0.1.0
