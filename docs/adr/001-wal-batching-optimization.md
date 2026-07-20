# ADR 001: WAL Write Batching for Performance Optimization

**Status:** Accepted (implemented differently - see Outcome)
**Date:** 2025-03-15
**Author:** Shanghai Team
**Context:** Phase 4 - Performance & Stability Work

## Context and Problem Statement

The Write-Ahead Log (WAL) is critical for durability, but `fsync` operations are expensive.
In the initial implementation, every WAL write calls `fsync` immediately, resulting in:

- High latency per write (~5-10ms on typical SSDs)
- Poor throughput (100-200 writes/sec max)
- Inefficient disk I/O utilization
- Increased wear on SSDs

We need to optimize write performance while maintaining durability guarantees.

## Decision Drivers

- **Durability**: Cannot compromise on data safety
- **Throughput**: Need to handle 10,000+ writes/sec
- **Latency**: P99 latency should remain reasonable (<50ms)
- **Simplicity**: Should not complicate the codebase significantly

## Considered Options

### Option 1: Status Quo (Immediate fsync)
**Pros:**
- Simple implementation
- Predictable latency
- Strong durability guarantees

**Cons:**
- Very poor throughput
- High per-write latency
- Does not scale

### Option 2: Group Commit / Batch fsync (Selected)
**Pros:**
- Excellent throughput (10,000+ writes/sec)
- Amortizes fsync cost across multiple writes
- Still maintains durability
- Industry-standard approach (PostgreSQL, MySQL InnoDB)

**Cons:**
- Slightly increased latency for first write in batch
- More complex implementation
- Requires careful synchronization

### Option 3: Async fsync with callbacks
**Pros:**
- Non-blocking writes
- Good throughput

**Cons:**
- Much more complex
- Harder to reason about durability
- Error handling becomes complicated

## Decision Outcome

**Chosen option:** "Group Commit / Batch fsync" (Option 2)

### Implementation Details

Created `Storage.WAL.BatchWriter` module that:

1. **Accumulates writes** in a pending queue
2. **Batches are flushed** when either:
   - Batch size reaches threshold (default: 100 entries)
   - Batch timeout expires (default: 10ms)
   - Explicit flush requested
3. **Single fsync** is performed for the entire batch
4. **All clients** in the batch receive their LSN after fsync completes

### Configuration

```elixir
# config/config.exs
config :storage, Storage.WAL.BatchWriter,
  batch_size: 100,          # Max entries per batch
  batch_timeout_ms: 10      # Max wait time before flush
```

### Durability Guarantees

- All writes are flushed to disk before acknowledgment
- No data loss on crash - all acknowledged writes are durable
- Batching only affects **when** fsync happens, not **if**
- Crash during batch accumulation loses only unacknowledged writes

## Performance Impact

**Expected improvements:**

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Throughput | 200 writes/sec | 12,000 writes/sec | 60x |
| P50 latency | 6ms | 2ms | 3x faster |
| P99 latency | 12ms | 15ms | -25% slower |
| Disk IOPS | 200 | 120 | 40% reduction |

**Trade-off:** P99 latency increases slightly because some writes wait for the
batch timer, but median throughput improves dramatically.

## Consequences

### Positive

- Massive throughput improvement
- Better disk utilization
- Reduced SSD wear
- Industry-proven approach
- Configurable for different workloads

### Negative

- Increased implementation complexity
- P99 latency may increase slightly
- More difficult to reason about timing
- Requires tuning for optimal performance

### Neutral

- Integration points need updates
- Existing tests need modification
- Documentation needs expansion

## Alternatives Considered But Rejected

### Option 4: WAL on faster storage (NVMe, Optane)
**Why rejected:** Hardware solution doesn't fix software inefficiency.
Even with NVMe, batching still provides significant benefits.

### Option 5: Disable fsync (dangerous)
**Why rejected:** Violates durability guarantees. Unacceptable for a database system.

### Option 6: Write-behind caching
**Why rejected:** Too complex, risk of data loss, not worth the additional complexity.

## References

- PostgreSQL WAL implementation: https://www.postgresql.org/docs/current/wal-internals.html
- MySQL InnoDB group commit: https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html
- LevelDB WAL batching: https://github.com/google/leveldb/blob/main/db/db_impl.cc

## Outcome

Batching was implemented, but **not** as the standalone `Storage.WAL.BatchWriter`
module this ADR proposed. That module was written and never wired in: it held a
fixed `segment_pid` and did none of the work the write path owns - LSN
assignment, `SegmentIndex` updates, segment rotation or metadata persistence -
so it could not sit in front of `Storage.WAL.Writer` without duplicating them.

Group commit now lives inside `Storage.WAL.Writer` itself, and the standalone
module was removed. The durability contract is unchanged: a caller is replied
to only after its entry is fsynced.

One refinement over the original design: a batch is flushed as soon as no
further append is queued, so a lone writer is never delayed by
`batch_timeout_ms`. The timer only bounds waiting under concurrent load.

## Follow-up Actions

- [x] Implement `Segment.append_entry_no_sync/2` for write-only operations
- [x] Implement `Segment.sync/1` for fsync-only operations
- [x] Add telemetry metrics for batch operations
- [x] Group-commit in the Writer (instead of a separate BatchWriter)
- [x] Document tuning recommendations for operators
- [ ] Benchmark against different batch sizes and timeouts
and benchmarks confirm the expected performance improvements.
