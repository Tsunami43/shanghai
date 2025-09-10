# Shanghai Operations Guide

This guide provides essential operational procedures for running Shanghai
in production environments.

## Table of Contents

- [Installation](#installation)
- [Configuration](#configuration)
- [Starting the Cluster](#starting-the-cluster)
- [Monitoring](#monitoring)
- [Backup and Recovery](#backup-and-recovery)
- [Scaling](#scaling)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

## Installation

### System Requirements

**Minimum:**
- CPU: 2 cores
- RAM: 4 GB
- Disk: 50 GB SSD
- Network: 1 Gbps
- OS: Linux (Ubuntu 20.04+ or RHEL 8+)

**Recommended (Production):**
- CPU: 8 cores
- RAM: 32 GB
- Disk: 500 GB NVMe SSD
- Network: 10 Gbps
- OS: Ubuntu 22.04 LTS

### Software Dependencies

```bash
# Erlang/OTP 26+
sudo apt-get update
sudo apt-get install erlang-base erlang-dev

# Elixir 1.15+
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install elixir

# Build tools
sudo apt-get install build-essential git
```

### Build from Source

```bash
git clone https://github.com/yourorg/shanghai.git
cd shanghai
mix deps.get
mix compile
mix release
```

## Configuration

### Environment Variables

```bash
# Node identification
export SHANGHAI_NODE_ID="node-1"
export SHANGHAI_HOST="10.0.1.10"
export SHANGHAI_PORT="4000"

# Storage
export SHANGHAI_DATA_DIR="/var/lib/shanghai/data"
export SHANGHAI_WAL_DIR="/var/lib/shanghai/wal"

# Clustering
export SHANGHAI_CLUSTER_NODES="node-1@10.0.1.10,node-2@10.0.1.11,node-3@10.0.1.12"

# Admin API
export SHANGHAI_ADMIN_PORT="9090"
```

### Configuration File

```elixir
# config/prod.exs
import Config

config :shanghai,
  node_id: System.get_env("SHANGHAI_NODE_ID") || "node-1",
  host: System.get_env("SHANGHAI_HOST") || "localhost",
  port: String.to_integer(System.get_env("SHANGHAI_PORT") || "4000")

config :storage,
  data_dir: System.get_env("SHANGHAI_DATA_DIR") || "/var/lib/shanghai/data",
  wal_dir: System.get_env("SHANGHAI_WAL_DIR") || "/var/lib/shanghai/wal",
  segment_size_threshold: 64 * 1024 * 1024

config :admin_api,
  port: String.to_integer(System.get_env("SHANGHAI_ADMIN_PORT") || "9090")

config :logger,
  level: :info
```

## Starting the Cluster

### Single Node (Development)

```bash
mix run --no-halt
```

### Multi-Node Cluster (Production)

**Node 1:**
```bash
_build/prod/rel/shanghai/bin/shanghai start
```

**Node 2:**
```bash
# Join existing cluster
shanghaictl node join node-2 --host=10.0.1.11 --port=4000
```

**Node 3:**
```bash
shanghaictl node join node-3 --host=10.0.1.12 --port=4000
```

### Verify Cluster

```bash
shanghaictl status

# Output:
# Shanghai Cluster Status
# ========================================
#
# Cluster State: Healthy
#
# Nodes:
#   ✓ node-1 - up (heartbeat: 50ms ago)
#   ✓ node-2 - up (heartbeat: 45ms ago)
#   ✓ node-3 - up (heartbeat: 60ms ago)
```

## Monitoring

### Built-in Metrics

```bash
# View all metrics
shanghaictl metrics

# View replication status
shanghaictl replicas

# Check cluster health
shanghaictl status
```

### Prometheus Integration

```elixir
# Add to config/prod.exs
config :shanghai,
  telemetry_prometheus_port: 9568
```

Metrics available at: `http://localhost:9568/metrics`

### Key Metrics to Monitor

| Metric | Alert Threshold | Description |
|--------|----------------|-------------|
| `shanghai_wal_write_latency_p99` | > 50ms | WAL write performance |
| `shanghai_replication_lag` | > 10000 offsets | Replication health |
| `shanghai_cluster_nodes_down` | > 0 | Node failures |
| `shanghai_disk_usage_percent` | > 85% | Disk space |

### Grafana Dashboard

Import the provided dashboard: `grafana/shanghai-dashboard.json`

## Backup and Recovery

### Backup Strategy

**Full Backup (Daily):**
```bash
#!/bin/bash
# backup.sh
BACKUP_DIR="/backup/shanghai/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Stop writes (optional)
shanghaictl shutdown --graceful

# Copy data
rsync -av /var/lib/shanghai/data/ $BACKUP_DIR/data/
rsync -av /var/lib/shanghai/wal/ $BACKUP_DIR/wal/

# Resume operations
_build/prod/rel/shanghai/bin/shanghai start
```

**Incremental Backup (Hourly):**
```bash
# Only backup WAL segments
rsync -av --include='segment_*.wal' /var/lib/shanghai/wal/ $BACKUP_DIR/wal/
```

### Recovery Procedure

**Point-in-Time Recovery:**
```bash
# 1. Stop node
shanghaictl shutdown --force

# 2. Restore data
rm -rf /var/lib/shanghai/data/*
rsync -av /backup/shanghai/20250915/data/ /var/lib/shanghai/data/

# 3. Restore WAL
rsync -av /backup/shanghai/20250915/wal/ /var/lib/shanghai/wal/

# 4. Start node
_build/prod/rel/shanghai/bin/shanghai start

# 5. Verify
shanghaictl status
```

## Scaling

### Adding a Node

```bash
# 1. Prepare new server
ssh new-node
cd shanghai
mix release

# 2. Configure
export SHANGHAI_NODE_ID="node-4"
export SHANGHAI_HOST="10.0.1.13"

# 3. Join cluster
shanghaictl node join node-4 --host=10.0.1.13 --port=4000

# 4. Verify
shanghaictl status | grep node-4
```

### Removing a Node

```bash
# Graceful removal
shanghaictl node leave node-4
shanghaictl status
```

### Rebalancing

Shanghai automatically rebalances shards when nodes join/leave.
No manual intervention required.

## Troubleshooting

### Node Won't Start

**Check logs:**
```bash
tail -f /var/log/shanghai/shanghai.log
```

**Common causes:**
- Port already in use
- Insufficient disk space
- Corrupt WAL segments

**Solutions:**
```bash
# Check ports
netstat -tulpn | grep 4000

# Check disk space
df -h /var/lib/shanghai

# Recover from corrupt WAL
rm /var/lib/shanghai/wal/segment_corrupt.wal
```

### High Replication Lag

**Diagnose:**
```bash
shanghaictl replicas
shanghaictl metrics | grep replication
```

**Common causes:**
- Slow network
- Follower disk I/O bottleneck
- CPU saturation

**Solutions:**
```bash
# Check network
iperf3 -c follower-host

# Check disk I/O
iostat -x 1 10

# Increase replication credits (temporary)
# Edit config and restart
```

### Memory Growth

**Check memory usage:**
```bash
# BEAM memory
shanghaictl metrics | grep memory

# System memory
free -h
```

**Common causes:**
- Slow followers (buffering)
- Subscriber leak (fixed in v1.2.0+)
- Too many metrics

**Solutions:**
- Upgrade to v1.2.0+
- Enable backpressure
- Restart node (temporary)

## Maintenance

### Upgrading

**Rolling upgrade (zero downtime):**
```bash
# For each node:
# 1. Stop node
shanghaictl shutdown --graceful

# 2. Upgrade binaries
mix release --overwrite

# 3. Start node
_build/prod/rel/shanghai/bin/shanghai start

# 4. Verify
shanghaictl status

# Wait for node to catch up before proceeding to next node
```

### Log Rotation

```bash
# /etc/logrotate.d/shanghai
/var/log/shanghai/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 shanghai shanghai
    sharedscripts
    postrotate
        systemctl reload shanghai
    endscript
}
```

### Performance Tuning

See [TUNING.md](TUNING.md) for detailed tuning recommendations.

### Health Checks

```bash
# Automated health check script
#!/bin/bash
# healthcheck.sh

STATUS=$(shanghaictl status | grep "Cluster State" | awk '{print $3}')

if [ "$STATUS" != "Healthy" ]; then
    echo "CRITICAL: Cluster unhealthy"
    exit 2
fi

echo "OK: Cluster healthy"
exit 0
```

## Production Checklist

Before going live:

- [ ] All nodes running latest stable version
- [ ] Monitoring configured (Prometheus/Grafana)
- [ ] Alerting rules defined and tested
- [ ] Backup strategy implemented and tested
- [ ] Disaster recovery plan documented
- [ ] Log rotation configured
- [ ] Performance tuning applied
- [ ] Security hardening completed
- [ ] Firewall rules configured
- [ ] Load testing completed at 2x expected peak
- [ ] Runbooks created for common issues
- [ ] On-call rotation established
- [ ] Escalation procedures defined

## Support

- Documentation: https://shanghai.readthedocs.io/
- Issues: https://github.com/yourorg/shanghai/issues
- Slack: #shanghai-users

## See Also

- [Performance Tuning](TUNING.md)
- [Architecture Decision Records](adr/)
- [Deprecation Notices](DEPRECATIONS.md)
