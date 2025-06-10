# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records for Shanghai distributed database.

## What is an ADR?

An ADR is a document that captures an important architectural decision made during the project,
along with its context and consequences.

## Format

Each ADR follows this structure:

- **Status**: Proposed | Accepted | Deprecated | Superseded
- **Date**: When the decision was made
- **Context**: What is the issue we're trying to solve?
- **Decision**: What did we decide?
- **Consequences**: What are the implications?

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [001](001-wal-batching-optimization.md) | WAL Write Batching for Performance Optimization | Proposed | 2025-03-15 |
| [002](002-telemetry-observability.md) | Telemetry-based Observability Architecture | Accepted | 2025-01-13 |
| [003](003-replication-backpressure.md) | Backpressure in Replication Streams | Proposed | 2025-03-15 |

## How to Create a New ADR

1. Copy the template below
2. Number it sequentially (e.g., `004-your-title.md`)
3. Fill in the sections
4. Submit for review
5. Update this index

## Template

```markdown
# ADR NNN: [Short Title]

**Status:** [Proposed | Accepted | Deprecated | Superseded]
**Date:** YYYY-MM-DD
**Author:** [Your Name]
**Context:** [Phase or Epic]

## Context and Problem Statement

[Describe the problem and why we need to make a decision]

## Decision Drivers

- [Driver 1]
- [Driver 2]
- ...

## Considered Options

### Option 1: [Name]
**Pros:**
- [Pro 1]

**Cons:**
- [Con 1]

### Option 2: [Name] (Selected)
[Similar format]

## Decision Outcome

**Chosen option:** "[Option Name]"

[Explain why this option was chosen]

## Consequences

### Positive
- [Consequence 1]

### Negative
- [Consequence 1]

### Neutral
- [Consequence 1]

## Follow-up Actions

- [ ] Action 1
- [ ] Action 2

## References

- [Link 1]
- [Link 2]
```

## References

- [Michael Nygard's ADR template](https://github.com/joelparkerhenderson/architecture-decision-record)
- [ADR GitHub Organization](https://adr.github.io/)
