# Replication

Log-based replication system for Shanghai distributed database.

## Overview

The Replication app provides leader-follower replication with configurable consistency levels, enabling distributed data durability and high availability.

## Architecture

### Core Components

- **Leader** - Coordinates writes and tracks follower acknowledgments
- **Follower** - Applies replicated entries and reports offset progress
- **Stream** - Batches and broadcasts WAL entries to followers
- **Monitor** - Tracks replication lag and health metrics
- **ReplicaGroup** - Domain aggregate managing replica state

### Value Objects

- **ReplicationOffset** - Position in replication log
- **ConsistencyLevel** - Write consistency guarantees

### Domain Events

- **LeaderElected** - New leader elected with term
- **ReplicaCaughtUp** - Lagging replica recovered
- **ReplicaFellBehind** - Replica detected lagging

## Consistency Levels

### :local
Fast writes with no durability guarantee. Completes on leader acknowledgment only.

### :leader
Balanced writes with ordering guarantee. Ensures strict ordering through leader.

### :quorum (default)
Durable writes requiring majority acknowledgment. Survives minority failures.

## Usage

See `Replication.Docs.ConsistencyGuide` for detailed examples and best practices.
