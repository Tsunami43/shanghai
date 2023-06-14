# CoreDomain

Shared domain language for Shanghai. A pure library with no processes and no
side effects, depended on by every other app; it defines the ubiquitous
vocabulary the system is built from.

## Key abstractions

- `CoreDomain.Types.LogSequenceNumber` — monotonic LSN, total ordering.
- `CoreDomain.Types.NodeId` — node identity.
- `CoreDomain.ValueObjects.ConsistencyLevel` — `:strong` / `:eventual` / `:causal`.
- `CoreDomain.Entities.LogEntry` — immutable write-ahead-log entry.
- `CoreDomain.Protocols.Event` — domain-event contract.
