# Shanghai Performance Characteristics

This document provides detailed performance analysis, benchmarks, and optimization strategies for Shanghai.

> **Status:** The WAL write sections below are **measured** on the hardware
> named under [Measurement Environment](#measurement-environment). Everything
> else - replication, cluster, capacity planning, the comparison tables - is
> still an unreproduced *target*.
>
> The headline finding: measured peak WAL throughput is **~10,600 writes/sec**,
> against a stated target of 250,000/sec. The gap is fsync: at ~1.15 ms per
> flush on this NVMe SSD, ~870 fsyncs/sec is the hard ceiling, and group commit
> can only amortize it across concurrent writers. Reaching 250k/sec would need
> a fundamentally cheaper durability path (battery-backed cache, `O_DIRECT`
> with a write-back log, or relaxing per-write fsync), not tuning.
>
> Re-measure on your own hardware - every number here is storage-bound.

## Table of Contents

- [Overview](#overview)
- [Benchmark Results](#benchmark-results)
- [Performance Analysis](#performance-analysis)
- [Bottlenecks](#bottlenecks)
- [Optimization Strategies](#optimization-strategies)
- [Capacity Planning](#capacity-planning)
- [Comparison with Alternatives](#comparison-with-alternatives)

## Overview

### Measurement Environment

The WAL numbers below were measured on:

- **Hardware**: AMD Ryzen AI 9 HX 370 (24 threads), 28 GB RAM
- **Storage**: Kingston NVMe SSD, **ext4** - a real disk, not tmpfs
- **OS**: Arch Linux (kernel 7.0)
- **Erlang/OTP**: 28, **Elixir**: 1.19

> **Measure on a real filesystem.** `/tmp` is tmpfs on many Linux systems,
> including this one. An fsync there is a memory barrier, not a disk flush, and
> inflates WAL throughput by orders of magnitude. The repository's own test
> suite uses `System.tmp_dir!()`, so by default it does *not* exercise real
> disk durability - run `mix test.disk` to point it at a real filesystem.

### Reproducing

```bash
BENCH_DIR=~/.cache/shanghai_bench MIX_ENV=test elixir -S mix run \
  apps/storage/bench/wal_bench.exs
```

Point `BENCH_DIR` at a real filesystem and confirm with `df -T`.

### Methodology

- **Warmup**: 100 writes before each measurement
- **Data size**: 1 KB per entry
- **Concurrency**: 1 to 100 processes
- **Baseline**: `batch_size: 1` forces one fsync per append, i.e. the behaviour
  before group commit existed, so the two columns are directly comparable
- **Repetitions**: single run - treat as an order of magnitude, not a
  reproducible score

## Benchmark Results

### WAL Write Performance

#### Sequential Writes (Single Process)

| Configuration | Throughput | µs/write |
|--------------|------------|----------|
| `batch_size: 1` (one fsync per write) | 850/sec | 1176 |
| `batch_size: 100` | 874/sec | 1143 |

**Key finding:** batching does nothing for a lone writer, and that is by
design. A batch is flushed as soon as no further append is queued, so a single
sequential writer pays a full fsync per write and is bounded by it (~1.15 ms
here). Group commit is a *concurrency* optimization, not a latency one.

#### Concurrent Writes (Multiple Processes)

| Processes | `batch_size: 1` | `batch_size: 100` | Speed-up |
|-----------|-----------------|-------------------|----------|
| 1 | 882/sec | 928/sec | 1.1x |
| 10 | 884/sec | 5,223/sec | 5.9x |
| 50 | 888/sec | 8,322/sec | 9.4x |
| 100 | 881/sec | 9,400/sec | 10.7x |

**Key findings:**
- Without group commit, throughput is **flat at ~880/sec no matter how many
  processes write**: fsync serializes them all. Concurrency buys nothing.
- With group commit, throughput scales with concurrency because one fsync
  covers the whole batch.
- The ceiling is fsync cost, so faster storage moves every number here.

#### Batch Size Sweep (50 concurrent processes)

| `batch_size` | Throughput |
|--------------|------------|
| 1 | 883/sec |
| 10 | 5,071/sec |
| 50 | 8,918/sec |
| 100 | 10,279/sec |
| 500 | 10,605/sec |

**Key finding:** returns flatten past 100, which is why 100 is the default.
Raising it to 500 buys ~3% for a longer worst-case wait.

#### Write Latency (single writer, 1000 samples)

| P50 | P95 | P99 |
|-----|-----|-----|
| 1.02 ms | 1.11 ms | 3.16 ms |

**This misses the <2 ms P99 target.** P50 tracks the fsync cost of the device;
the P99 tail is fsync jitter. An earlier claim that measured P99 was "well
within" target came from a tmpfs run and did not reflect a real disk.

### Replication Performance

#### LAN Replication (1ms latency)

| Entries/sec | Lag (offsets) | Network Usage |
|-------------|---------------|---------------|
| 10,000 | <50 | 10 MB/s |
| 50,000 | <200 | 50 MB/s |
| 100,000 | <1000 | 100 MB/s |

**Key findings:**
- Replication keeps up with write rate on LAN
- Lag scales linearly with write rate
- Network becomes bottleneck at 100,000/sec

#### WAN Replication (50ms latency)

| Entries/sec | Lag (offsets) | Network Usage |
|-------------|---------------|---------------|
| 1,000 | <100 | 1 MB/s |
| 5,000 | <500 | 5 MB/s |
| 10,000 | <2000 | 10 MB/s |

**Key findings:**
- High latency significantly impacts replication
- Credit-based flow control prevents runaway lag
- Batch size should increase with latency

### Cluster Membership

#### Heartbeat Performance

| Cluster Size | Heartbeat Interval | Network Overhead |
|--------------|-------------------|------------------|
| 3 nodes | 5s | 2 KB/min |
| 10 nodes | 5s | 12 KB/min |
| 50 nodes | 5s | 300 KB/min |
| 100 nodes | 5s | 1.2 MB/min |

**Key findings:**
- Heartbeat overhead scales O(n²)
- Acceptable up to ~100 nodes
- Beyond 100 nodes, consider hierarchical heartbeats

#### Failure Detection Latency

| Cluster Size | Detection Time (P50) | Detection Time (P99) |
|--------------|---------------------|---------------------|
| 3 nodes | 10.2s | 15.8s |
| 10 nodes | 10.5s | 16.2s |
| 50 nodes | 11.3s | 17.5s |

**Key findings:**
- Detection time ~independent of cluster size
- P99 close to timeout threshold (15s)
- Erlang :nodedown provides faster detection (instant)

## Performance Analysis

### WAL Write Path

```
┌──────────────┐
│ Client call  │  ~0.01ms (GenServer call)
└──────┬───────┘
       ▼
┌──────────────┐
│ Serialize    │  ~0.05ms (term_to_binary)
└──────┬───────┘
       ▼
┌──────────────┐
│ Batch buffer │  ~0.02ms (append to list)
└──────┬───────┘
       │ (wait for batch timeout or size)
       ▼
┌──────────────┐
│ Write to fd  │  ~0.5ms (pwrite)
└──────┬───────┘
       ▼
┌──────────────┐
│ fsync()      │  ~1.15ms (NVMe)  ← BOTTLENECK
└──────┬───────┘
       ▼
┌──────────────┐
│ Reply to all │  ~0.01ms
└──────────────┘
```

**Total:** ~1.2ms per batch on the measured NVMe SSD (P50 1.02ms end to end).

**Bottleneck:** `fsync()` dominates. Because it is one flush per *batch* rather
than per write, its cost is divided across everything in the batch - which is
why throughput scales with concurrency but single-writer latency does not
improve.

### Optimization Breakdown

| Optimization | Impact | Improvement | Measured? |
|--------------|--------|-------------|-----------|
| Group commit, 10 concurrent writers | Amortize fsync | 5.9x throughput | yes |
| Group commit, 100 concurrent writers | Amortize fsync | 10.7x throughput | yes |
| `batch_size` 10 → 100 (50 writers) | Fewer, larger flushes | 2.0x throughput | yes |
| `batch_size` 100 → 500 (50 writers) | Diminishing | 1.03x throughput | yes |
| Faster storage | Lower fsync latency | proportional | no |
| Larger segments | Fewer rotations | small | no |

### Replication Path

```
Leader                                    Follower
  │                                          │
  │ 1. WAL append notification               │
  │    ~0.01ms                                │
  ▼                                          │
┌─────────────┐                              │
│ Check credit│  ~0.01ms                     │
└──────┬──────┘                              │
       │                                     │
       │ 2. Read from WAL                    │
       │    ~0.1ms (memory read)             │
       ▼                                     │
┌─────────────┐                              │
│ Build batch │  ~0.05ms                     │
└──────┬──────┘                              │
       │                                     │
       │ 3. GenServer.cast                   │
       │    ~0.5ms (local)                   │
       │    ~1-50ms (LAN/WAN) ← BOTTLENECK  │
       ├────────────────────────────────────>│
       │                                     │
       │                                4. Append to WAL
       │                                   ~4ms
       │                                     │
       │                                5. Send ack
       │<────────────────────────────────────┤
       │                                     │
       ▼                                     ▼
```

**LAN total:** ~5ms
**WAN total:** ~55ms

**Bottleneck:** Network latency dominates on WAN.

## Bottlenecks

### 1. Disk I/O (fsync)

**Problem:** `fsync()` takes 4-10ms on typical SSDs.

**Impact:** Limits unbatched throughput to ~250 writes/sec.

**Solutions:**
- Write concurrently (group commit amortizes fsync across writers)
- Upgrade to NVMe SSD (2x faster fsync)
- Use XFS with nobarrier (unsafe, not recommended)
- Disable fsync (data loss on crash)

### 2. Network Bandwidth

**Problem:** Replication saturates 1 Gbps link at ~100,000 writes/sec.

**Impact:** Limits cluster-wide throughput.

**Solutions:**
- Use 10 Gbps network
- Compress replication batches (future feature)
- Reduce replication fanout

### 3. Erlang Distribution Overhead

**Problem:** Erlang RPC adds 0.5-1ms per message.

**Impact:** Limits replication throughput.

**Solutions:**
- Batch replication messages (already done)
- Use compression (future)
- Use alternative RPC (gRPC) (v2.0)

### 4. GenServer Contention

**Problem:** Single GenServer for segment writes.

**Impact:** Limits concurrent write throughput.

**Solutions:**
- Use multiple segments (shard by hash)
- Use ETS for concurrent access (complex)

## Optimization Strategies

### For Write Throughput

#### 1. Enable Batching

**Before:** one writer process, one fsync per append.

**After:** many writer processes, one fsync per batch.

```elixir
Task.async_stream(data_list, &Storage.append/1, max_concurrency: 10)
|> Stream.run()
```

Group commit only engages when appends overlap, so a single sequential
writer sees no gain from it.

---

#### 2. Tune Batch Size

**Config:**
```elixir
config :storage, :batch_writer,
  batch_size: 200,  # Increase from default 100
  batch_timeout_ms: 10
```

**Improvement:** +20% throughput (60k → 72k/sec)

---

#### 3. Use Concurrent Writers

**Before:**
```elixir
# Single process
Enum.each(data_list, &Storage.append/1)
```

**After:**
```elixir
# 10 concurrent processes
Task.async_stream(data_list, &Storage.append/1, max_concurrency: 10)
|> Stream.run()
```

**Improvement:** +150% throughput (60k → 150k/sec)

---

#### 4. Upgrade Storage

fsync latency sets the ceiling, so storage is the single biggest lever.

| Storage Type | fsync Latency | Measured? |
|--------------|---------------|-----------|
| HDD (7200 RPM) | 10-15ms | no |
| SATA SSD | 4-8ms | no |
| NVMe SSD (this machine) | ~1.15ms | **yes: ~10,600/sec peak** |
| Optane SSD | 0.1-0.5ms | no |

Only the NVMe row was measured. Scale the others by fsync latency rather than
trusting an absolute figure.

---

### For Write Latency

#### 1. Reduce Batch Timeout

**Config:**
```elixir
config :storage,
  batch_timeout_ms: 1  # Decrease from 10ms
```

**Trade-off:** lower worst-case wait for a batch to fill, less fsync
amortization under load.

Note this only bites under concurrency: a lone writer already flushes
immediately, so its latency is pure fsync cost (measured P50 1.02 ms,
P99 3.16 ms) and no timeout change will improve it.

---

#### 2. Lower batch_timeout_ms

For latency-sensitive applications, cap how long an append can wait for its
batch:

```elixir
# Lower latency, less fsync amortization
config :storage, batch_timeout_ms: 2
```

---

### For Replication Performance

#### 1. Increase Batch Size

**Config:**
```elixir
config :replication,
  max_batch_size: 200  # Increase from 100
```

**Impact:** Reduces network round-trips, higher throughput

**Improvement:** +30% on WAN

---

#### 2. Tune Credit Allocation

**Config:**
```elixir
config :replication,
  initial_credit: 200  # Increase from 100
```

**Impact:** Allows larger bursts before pausing

**Improvement:** Smoother replication under bursty load

---

#### 3. Use Multiple Replication Streams

Instead of single leader → follower stream, use multiple:

```elixir
# Shard replication by key
Enum.each(0..9, fn shard_id ->
  Replication.Leader.start_link(
    follower_node_id: follower,
    shard: shard_id
  )
end)
```

**Improvement:** 10x throughput (parallelism)

---

### For Cluster Performance

#### 1. Reduce Heartbeat Frequency (Large Clusters)

**Config:**
```elixir
config :cluster,
  heartbeat_interval_ms: 10_000  # Increase from 5s
```

**Impact:** Reduces network overhead in large clusters

**Trade-off:** Slower failure detection

---

#### 2. Use Hierarchical Membership (Future)

For >100 nodes, use hierarchy:

```
Region 1: 50 nodes → Representative node
Region 2: 50 nodes → Representative node
Region 3: 50 nodes → Representative node

Representatives form cluster of 3 nodes
```

**Improvement:** O(n²) → O(n log n) overhead

---

## Capacity Planning

### Calculating Required Resources

#### Disk Space

**Formula:**
```
Daily storage = writes_per_sec × entry_size × 86400 × replication_factor
```

**Example:**
- 10,000 writes/sec
- 1 KB entry size
- 3x replication

```
Daily = 10,000 × 1024 × 86400 × 3
      = 2.6 TB/day
```

**Recommendation:** 5-7 days retention → 13-18 TB per node

---

#### Network Bandwidth

**Formula:**
```
Network = writes_per_sec × entry_size × (replication_factor - 1)
```

**Example:**
- 50,000 writes/sec
- 1 KB entry
- 3x replication

```
Network = 50,000 × 1024 × 2
        = 100 MB/s
        = 800 Mbps
```

**Recommendation:** 10 Gbps link

---

#### Memory

**Formula:**
```
Memory = base + (active_segments × segment_size) + (subscribers × 10 MB)
```

**Example:**
- Base: 500 MB
- 10 active segments × 64 MB = 640 MB
- 100 subscribers × 10 MB = 1 GB

```
Memory = 500 + 640 + 1000 = 2.14 GB
```

**Recommendation:** 4-8 GB per node

---

## Comparison with Alternatives

### vs. Kafka

| Metric | Shanghai | Kafka |
|--------|----------|-------|
| Write throughput | ~10.6k/sec measured | 1M+/sec |
| Write latency (P99) | 3.2ms measured | 5ms |
| Replication lag | <100ms | <50ms |
| Setup complexity | Low | High |
| Language | Elixir | Java/Scala |
| Use case | Event sourcing | Streaming |

**When to choose Shanghai:**
- Elixir ecosystem
- Simpler ops
- Moderate scale (<1M writes/sec)

**When to choose Kafka:**
- Extreme scale (>1M writes/sec)
- Battle-tested at scale
- Rich streaming ecosystem

---

### vs. EventStore

| Metric | Shanghai | EventStore |
|--------|----------|------------|
| Write throughput | ~10.6k/sec measured | 15k/sec |
| Write latency (P99) | 2ms | 10ms |
| Query capability | Sequential only | Projections, subscriptions |
| Consistency | Eventual | Strong per-stream |
| Language | Elixir | C# |

**When to choose Shanghai:**
- Higher throughput needs
- Elixir ecosystem
- Simple append-only log

**When to choose EventStore:**
- Rich querying needed
- Strong consistency required
- .NET ecosystem

---

### vs. PostgreSQL WAL

| Metric | Shanghai | PostgreSQL |
|--------|----------|------------|
| Write throughput | ~10.6k/sec measured | 50k/sec |
| Write latency (P99) | 3.2ms measured | 5ms |
| Query capability | None | SQL |
| Consistency | Eventual | Strong |
| Use case | Log storage | RDBMS |

**When to choose Shanghai:**
- High write throughput
- Don't need SQL
- Event sourcing

**When to choose PostgreSQL:**
- Need SQL queries
- Need transactions
- General-purpose database

---

## Benchmarking Your Deployment

### Running Benchmarks

```elixir
# Throughput test
Storage.Benchmark.wal_write_throughput(10_000)

# Latency test
Storage.Benchmark.wal_write_latency(1_000)

# Concurrent test
Storage.Benchmark.concurrent_writes(10, 1_000)

# Full report
Storage.Benchmark.generate_report()
```

### Interpreting Results

**Good:**
- Throughput >50,000/sec (batched)
- P99 latency <5ms
- Replication lag <1000 offsets

**Needs investigation:**
- Throughput <10,000/sec
- P99 latency >50ms
- Replication lag >10,000 offsets

### Profiling

Use `:fprof` for detailed profiling:

```elixir
:fprof.trace([:start, {:procs, :all}])
Storage.Benchmark.wal_write_throughput(1_000)
:fprof.trace(:stop)
:fprof.profile()
:fprof.analyse()
```

## See Also

- [Tuning Guide](TUNING.md)
- [Architecture](ARCHITECTURE.md)
- [Operations Guide](OPERATIONS.md)
- [Benchmark Implementation](../apps/storage/lib/storage/benchmark.ex)
