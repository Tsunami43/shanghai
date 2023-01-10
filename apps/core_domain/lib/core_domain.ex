defmodule CoreDomain do
  @moduledoc """
  CoreDomain - Shared domain models, types, protocols, and behaviors.

  This is the foundation layer of the Shanghai distributed database.
  It contains no dependencies and defines the core domain language
  used across all bounded contexts.

  ## Modules

  - `CoreDomain.Types` - Core types (LSN, NodeId, Timestamp, Version)
  - `CoreDomain.Events` - Event definitions and protocols
  - `CoreDomain.Entities` - Domain entities (LogEntry, AggregateRoot)
  - `CoreDomain.ValueObjects` - Value objects (ConsistencyLevel, ReplicationMode)
  - `CoreDomain.Protocols` - Shared protocols (Event, Serializable, Validatable)

  ## Design Principles

  - All types are immutable
  - No side effects or I/O operations
  - Pure functions only
  - No dependencies on other apps
  """
end
