# ADR 002: Telemetry-based Observability Architecture

**Status:** Accepted
**Date:** 2025-01-13
**Author:** Shanghai Team
**Context:** Phase 4 - Observability & Tooling

## Context and Problem Statement

Shanghai needs comprehensive observability to operate effectively in production:

- Operators need visibility into WAL performance, replication lag, cluster health
- Debugging production issues requires detailed metrics
- Performance tuning requires measurable data
- External monitoring systems need integration points

We need an observability system that:
- Has minimal performance impact
- Integrates cleanly with existing code
- Supports external monitoring tools
- Provides both real-time and historical data

## Decision Drivers

- **Low overhead**: Metrics should not impact performance
- **Flexibility**: Should support various metric consumers
- **Standard approach**: Use Erlang/Elixir ecosystem best practices
- **Extensibility**: Easy to add new metrics
- **Integration**: Works with Prometheus, Grafana, etc.

## Considered Options

### Option 1: Custom metrics system
**Pros:**
- Full control over implementation
- Can optimize for our specific needs

**Cons:**
- Reinventing the wheel
- No ecosystem support
- Higher maintenance burden

### Option 2: :telemetry with custom reporter (Selected)
**Pros:**
- Standard Erlang/Elixir approach
- Rich ecosystem (telemetry_metrics, telemetry_poller)
- Low overhead (async event emission)
- Easy integration with external systems
- Well-documented and battle-tested

**Cons:**
- Learning curve for team
- Additional dependency

### Option 3: Logger-based metrics
**Pros:**
- Already have Logger
- Simple implementation

**Cons:**
- Not designed for metrics
- Poor performance at scale
- Difficult to aggregate

## Decision Outcome

**Chosen option:** ":telemetry with custom reporter" (Option 2)

### Architecture

```
┌─────────────────────────────────────────────────┐
│                  Application                     │
│  (Cluster, Storage, Replication modules)        │
└────────────┬────────────────────────────────────┘
             │ Emit events via
             │ Observability.Metrics
             ▼
┌─────────────────────────────────────────────────┐
│          :telemetry event bus                   │
└────────┬────────────────────────────────────────┘
         │
         ├──► Observability.MetricsReporter
         │    (In-memory aggregation)
         │
         ├──► telemetry_metrics_prometheus
         │    (Prometheus exporter)
         │
         └──► Custom handlers
              (Alerting, logging, etc.)
```

### Implementation Modules

1. **Observability.Metrics**
   - Convenience API for emitting events
   - Standardized event naming
   - Consistent metadata format

2. **Observability.MetricsReporter**
   - GenServer that aggregates metrics
   - Provides query API for Admin API
   - Maintains rolling statistics (count, sum, min, max, avg)

3. **Observability.Logger**
   - Structured logging with correlation IDs
   - Request tracing across distributed system
   - Integrates with telemetry events

### Event Categories

#### Storage Events
```elixir
[:shanghai, :storage, :wal, :write]       # WAL write duration
[:shanghai, :storage, :wal, :sync]        # fsync duration
[:shanghai, :storage, :compaction, :complete]  # Compaction metrics
```

#### Replication Events
```elixir
[:shanghai, :replication, :lag]           # Follower lag behind leader
[:shanghai, :replication, :catchup]       # Catch-up duration
```

#### Cluster Events
```elixir
[:shanghai, :cluster, :heartbeat]         # Heartbeat RTT
[:shanghai, :cluster, :membership_change] # Node join/leave/down
```

### Usage Example

```elixir
# Emit metric
Observability.Metrics.wal_write_completed(duration_ms, bytes, segment_id)

# Attach handler
:telemetry.attach(
  "my-handler",
  [:shanghai, :storage, :wal, :write],
  &MyModule.handle_event/4,
  nil
)

# Query aggregated metrics
{:ok, stats} = Observability.MetricsReporter.get_wal_stats()
```

## Consequences

### Positive

- Industry-standard approach
- Rich ecosystem support
- Low performance overhead
- Easy to extend with new metrics
- Supports multiple metric consumers
- Works with Prometheus, StatsD, etc.

### Negative

- Additional dependency (:telemetry)
- Requires training for team
- Event naming conventions must be followed

### Neutral

- Metrics are async (eventual consistency)
- Requires explicit event emission in code
- Need to maintain MetricsReporter for aggregation

## Integration Points

### Admin API
Exposes aggregated metrics via GET /api/v1/metrics for CLI tools.

### Prometheus
Can integrate telemetry_metrics_prometheus for external monitoring.

### Alerting
Can attach handlers for threshold-based alerts.

### Logging
Correlation IDs propagate through telemetry events.

## Performance Impact

- Event emission: ~1-2µs overhead per metric
- Async processing: no blocking
- Memory: O(number of unique metric keys)
- Negligible impact on application performance

## Follow-up Actions

- [x] Implement Observability.Metrics
- [x] Implement Observability.MetricsReporter
- [x] Implement Observability.Logger
- [x] Integrate metrics into Cluster modules
- [x] Integrate metrics into Storage modules
- [x] Add GET /api/v1/metrics endpoint
- [ ] Add telemetry_metrics_prometheus integration
- [ ] Document metrics for operators
- [ ] Create Grafana dashboards

## References

- :telemetry documentation: https://hexdocs.pm/telemetry/
- telemetry_metrics: https://hexdocs.pm/telemetry_metrics/
- Observability best practices: https://opentelemetry.io/
