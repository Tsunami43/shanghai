# ADR 003: Backpressure in Replication Streams

**Status:** Proposed
**Date:** 2025-03-15
**Author:** Shanghai Team
**Context:** Phase 4 - Performance & Stability Work

## Context and Problem Statement

Replication streams can produce data faster than followers can consume it, leading to:

- Unbounded memory growth on leader (buffering outgoing data)
- Unbounded mailbox growth on followers (incoming messages)
- Potential OOM crashes under high load
- Difficult to reason about system capacity

We need a mechanism to prevent the leader from overwhelming slow followers.

## Decision Drivers

- **Stability**: System must not crash under load
- **Fairness**: One slow follower shouldn't block others
- **Simplicity**: Should be easy to understand and debug
- **Performance**: Should not impact fast followers
- **Observability**: Must be able to detect backpressure

## Considered Options

### Option 1: No backpressure (current state)
**Pros:**
- Simple implementation
- Maximum throughput for fast followers

**Cons:**
- Unbounded memory usage
- System crashes under load
- No protection against slow followers
- **Unacceptable for production**

### Option 2: TCP flow control only
**Pros:**
- Handled by OS
- No application-level code needed

**Cons:**
- Too coarse-grained
- Can still overwhelm GenServer mailboxes
- No application-level visibility

### Option 3: GenStage-based replication (Considered)
**Pros:**
- Built-in backpressure support
- Well-tested Elixir library
- Demand-driven flow control

**Cons:**
- Significant architectural change
- May be over-engineered for our needs
- Learning curve for team

### Option 4: Credit-based flow control (Selected)
**Pros:**
- Application-level control
- Simple to implement and understand
- Fine-grained control per follower
- Industry-standard approach (Kafka, RabbitMQ)
- Can detect and handle slow followers

**Cons:**
- Requires changes to replication protocol
- Need to track credits per follower

## Decision Outcome

**Chosen option:** "Credit-based flow control" (Option 4)

### Design

Each follower has a credit balance:
- **Initial credits**: 1000 (configurable)
- **Sending**: Leader decrements credits before sending
- **Replenishment**: Follower sends ACK to replenish credits
- **Zero credits**: Leader stops sending to that follower

#### Protocol Flow

```
Follower                          Leader
   │                                │
   ├──────── CREDIT_REQUEST ───────►│ (Initial: 1000)
   │                                │
   │◄──────── LOG_ENTRY[1] ─────────┤ (Credits: 999)
   │◄──────── LOG_ENTRY[2] ─────────┤ (Credits: 998)
   │                                │
   ├──────── ACK[1..100] ──────────►│ (Replenish: +100)
   │                                │
   ... continues ...
   │                                │
   │◄──────── LOG_ENTRY[N] ─────────┤ (Credits: 1)
   │                                │ (No more credits, pause)
   │                                │
   ├──────── ACK[N-99..N] ─────────►│ (Replenish: +100)
   │◄──────── LOG_ENTRY[N+1] ───────┤ (Resume)
```

### Implementation

```elixir
defmodule Replication.Stream do
  defstruct [
    :follower_id,
    :socket,
    :credits,           # Current credits
    :max_credits,       # Maximum credits
    :pending_entries    # Queue of entries waiting for credits
  ]

  def send_entry(stream, entry) do
    cond do
      stream.credits > 0 ->
        # Send immediately
        :ok = send_log_entry(stream.socket, entry)
        %{stream | credits: stream.credits - 1}

      true ->
        # Queue until credits available
        pending = :queue.in(entry, stream.pending_entries)
        %{stream | pending_entries: pending}
    end
  end

  def handle_ack(stream, acked_count) do
    new_credits = min(stream.credits + acked_count, stream.max_credits)
    stream = %{stream | credits: new_credits}

    # Drain pending queue if we have credits now
    drain_pending(stream)
  end
end
```

### Configuration

```elixir
# config/config.exs
config :replication, Replication.Stream,
  max_credits: 1000,        # Maximum outstanding entries
  ack_batch_size: 100,      # ACK every N entries
  credit_warning: 100       # Emit warning when credits drop below
```

### Slow Follower Handling

When a follower's credits reach zero:
1. **Log warning**: "Follower #{id} has exhausted credits (backpressure)"
2. **Emit metric**: `[:shanghai, :replication, :backpressure]`
3. **Continue**: Leader continues serving other followers
4. **Resume**: When follower catches up and sends ACK

If follower remains at zero credits for > threshold:
1. **Mark as lagging**: Update follower status
2. **Alert operators**: Via metrics and logs
3. **Consider removal**: May need to remove from replica set

## Consequences

### Positive

- **Stability**: Bounded memory usage, no OOM crashes
- **Fairness**: One slow follower doesn't block others
- **Observability**: Clear metrics when backpressure occurs
- **Performance**: Fast followers unaffected
- **Industry-proven**: Used by Kafka, RabbitMQ, etc.

### Negative

- **Protocol complexity**: Need to handle credit messages
- **Latency**: Slow followers may lag further behind
- **Implementation effort**: Requires changes to replication layer

### Neutral

- **Tuning required**: Need to find optimal credit values
- **Monitoring needed**: Must watch for chronic backpressure

## Performance Impact

**Expected behavior:**

| Scenario | Before | After |
|----------|--------|-------|
| All fast followers | 100K msgs/sec | 100K msgs/sec (no change) |
| One slow follower | OOM crash | Slow follower lags, others continue |
| Bursty traffic | Potential crash | Smooth degradation |
| Memory usage | Unbounded | Bounded by (followers × max_credits) |

## Monitoring

### Metrics

```elixir
# Credit exhaustion
[:shanghai, :replication, :credits_exhausted]
# Metadata: {group_id, follower_id}

# Current credit balance
[:shanghai, :replication, :credit_balance]
# Measurements: {current_credits, max_credits}

# Pending queue depth
[:shanghai, :replication, :pending_queue_depth]
# Measurements: {depth}
```

### Alerts

- **Warning**: Credits < 20% of max
- **Critical**: Credits = 0 for > 60 seconds

## Alternatives Considered But Rejected

### Option 5: Drop messages for slow followers
**Why rejected:** Breaks consistency guarantees. Unacceptable for a database.

### Option 6: Disconnect slow followers
**Why rejected:** Too aggressive, doesn't allow temporary slowdown recovery.

### Option 7: Throttle leader writes
**Why rejected:** Punishes all clients for one slow follower.

## References

- Apache Kafka flow control: https://kafka.apache.org/documentation/#design_flowcontrol
- RabbitMQ credit flow: https://www.rabbitmq.com/flow-control.html
- Akka Streams backpressure: https://doc.akka.io/docs/akka/current/stream/stream-rate.html

## Follow-up Actions

- [ ] Implement credit tracking in Replication.Stream
- [ ] Add ACK protocol messages
- [ ] Integrate with existing replication flow
- [ ] Add telemetry for credit exhaustion
- [ ] Update documentation for operators
- [ ] Load test with mixed fast/slow followers
- [ ] Document tuning recommendations

## Notes

This ADR will be updated to "Accepted" once the implementation is complete
and tested under load with slow followers.
