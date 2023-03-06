# Shanghai Performance Tuning Guide

This guide provides recommendations for tuning Shanghai for optimal performance
in production environments.

## WAL Configuration

### Write Performance

```elixir
# config/config.exs
config :storage, Storage.WAL.BatchWriter,
  batch_size: 100,         # Entries per batch
  batch_timeout_ms: 10     # Max wait before flush
```

**Recommendations:**
- **High throughput workload**: Increase `batch_size` to 200-500
- **Low latency workload**: Decrease `batch_timeout_ms` to 5ms
- **Mixed workload**: Keep defaults (100 entries, 10ms)

### Segment Rotation

```elixir
config :storage, Storage.WAL.Writer,
  segment_size_threshold: 64 * 1024 * 1024,  # 64 MB
  segment_time_threshold: 3600                # 1 hour
```

**Recommendations:**
- **SSD storage**: 64-128 MB segments
- **HDD storage**: 256-512 MB segments (fewer seeks)
- **High write rate**: Rotate more frequently (30 min)

## Replication Tuning

### Flow Control

```elixir
config :replication, Replication.Stream,
  max_credits: 1000,        # Outstanding entries
  ack_batch_size: 100       # ACK frequency
```

**Recommendations:**
- **Fast network**: Increase `max_credits` to 2000-5000
- **Slow network**: Decrease to 500
- **Low latency**: Decrease `ack_batch_size` to 50

### Monitoring Thresholds

```elixir
config :replication, Replication.Monitor,
  lag_threshold: 1000,           # Offsets behind leader
  stale_threshold_ms: 30_000,    # No updates in 30s
  check_interval_ms: 5_000       # Health check every 5s
```

**Recommendations:**
- **Strict consistency**: `lag_threshold` = 100
- **Eventual consistency**: `lag_threshold` = 5000
- **Alert on lag > 10,000 offsets**

## Cluster Configuration

### Heartbeat Tuning

```elixir
config :cluster, Cluster.Heartbeat,
  interval_ms: 5_000,           # Send heartbeat every 5s
  timeout_ms: 15_000,           # Mark down after 15s
  suspect_timeout_ms: 10_000    # Mark suspect after 10s
```

**Recommendations:**
- **Stable network**: Keep defaults
- **Unstable network**: Increase timeouts (20s/30s)
- **Fast failure detection**: Decrease (2s/6s/4s)

## Storage Backend

### Filesystem Recommendations

**Best:** XFS or ext4 with `noatime,nodiratime`

```bash
mount -o noatime,nodiratime /dev/sda1 /var/lib/shanghai
```

**Avoid:** NFS, network-mounted filesystems

### SSD Optimization

```bash
# Enable TRIM support
echo 1 > /sys/block/sda/queue/discard_granularity

# Set I/O scheduler
echo "deadline" > /sys/block/sda/queue/scheduler
```

## Memory Configuration

### Erlang VM

```bash
# Start with appropriate memory limits
erl +MBas ageffcbf +MBac cffc +MBscs 4096
```

**Recommendations:**
- **Small deployment**: 2-4 GB heap
- **Medium deployment**: 8-16 GB heap
- **Large deployment**: 32-64 GB heap

### Buffer Sizes

```elixir
config :kernel,
  inet_default_connect_options: [
    send_buffer: 256 * 1024,     # 256 KB send buffer
    recv_buffer: 256 * 1024      # 256 KB recv buffer
  ]
```

## Observability Overhead

### Telemetry Impact

Typical overhead: 1-2µs per metric emission

**Recommendations:**
- Keep all default metrics enabled
- Add custom metrics sparingly
- Use sampling for high-frequency events

### Logging

```elixir
config :logger,
  level: :info,              # Production
  truncate: 8192,            # Truncate large messages
  discard_threshold: 500     # Discard if queue > 500
```

**Debug mode impact:** 10-20% throughput reduction

## Benchmarking

### WAL Write Throughput

```bash
# Run benchmark
mix run -e "Storage.Benchmark.wal_write_throughput(10_000)"

# Expected results:
# - Baseline (no batching): 200 writes/sec
# - With batching: 10,000-15,000 writes/sec
```

### Replication Lag

```bash
# Monitor lag
shanghaictl metrics | grep replication

# Acceptable lag:
# - < 100 offsets: Excellent
# - 100-1000: Good
# - 1000-10000: Acceptable
# - > 10000: Investigation needed
```

## Capacity Planning

### Disk Space

**Rule of thumb:** 3x data size for WAL + compaction overhead

```
Data size: 100 GB
Required: 300 GB
```

### Network Bandwidth

**Per replica:**
- Average: 10-50 MB/sec
- Peak: 100-200 MB/sec

**3-node cluster:** 150-300 MB/sec total

### CPU Usage

**Typical load:**
- WAL writes: 10-20% CPU per core
- Compaction: 30-50% CPU during compaction
- Replication: 5-10% CPU per follower

**Recommendation:** 4-8 cores for production

## Common Issues

### High WAL Latency

**Symptoms:** P99 > 100ms

**Causes:**
- Slow disk (check with `iostat`)
- Too small batch size
- Disk nearly full (> 95%)

**Solutions:**
- Upgrade to SSD
- Increase `batch_size`
- Add more disk space

### Replication Lag

**Symptoms:** Lag > 10,000 offsets

**Causes:**
- Network congestion
- Slow follower disk
- CPU saturation on follower

**Solutions:**
- Increase `max_credits`
- Upgrade follower hardware
- Add more followers to distribute load

### Memory Growth

**Symptoms:** Continuous memory increase

**Causes:**
- Slow followers (buffering)
- Too many metrics
- Memory leak (report bug)

**Solutions:**
- Enable backpressure (check credits)
- Reduce metric retention
- Restart node (temporary)

## Production Checklist

- [ ] WAL on SSD storage
- [ ] `noatime` mount option enabled
- [ ] Adequate disk space (3x data)
- [ ] Network bandwidth sufficient
- [ ] Monitoring configured (Prometheus)
- [ ] Alerting rules defined
- [ ] Backup strategy in place
- [ ] Disaster recovery plan documented
- [ ] Load tested at 2x expected peak
- [ ] Tuning applied per workload

## References

- [ADR 001: WAL Batching](adr/001-wal-batching-optimization.md)
- [ADR 003: Replication Backpressure](adr/003-replication-backpressure.md)
- [Observability Guide](OBSERVABILITY.md)
