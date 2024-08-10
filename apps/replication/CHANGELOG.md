# Changelog

All notable changes to the Replication app will be documented in this file.

## [Unreleased]

### Q4 2024
- Basic failure scenario tests
- Quorum calculation utilities  
- Consistency level documentation and guide

### Q3 2024
- Consistency level value object (:local, :quorum, :leader)
- Quorum-based write acknowledgment
- Per-operation consistency control
- Comprehensive consistency tests

### Q2 2024
- Stream GenServer with batching
- Replica catch-up mechanism  
- Replication Monitor for lag tracking
- Health status detection (healthy/lagging/stale)

### Q1 2024
- ReplicaGroup aggregate and domain model
- Leader and Follower GenServers
- Leader-based write coordination
- Registry for process management
- Domain events (LeaderElected, ReplicaCaughtUp, ReplicaFellBehind)
- ReplicationOffset tracking
- Comprehensive test coverage

## [0.1.0] - 2024-01-03

Initial implementation of replication subsystem.
