import Config

# Production environment configuration

# In production, data_root should be set via runtime configuration
# or system environment variables. This is just a default.
config :storage,
  # Override this with runtime config or ENV var
  data_root: System.get_env("STORAGE_DATA_ROOT") || "/var/lib/shanghai/data",
  node_id: System.get_env("NODE_ID") || "prod_node_1",

  # Production-optimized rotation thresholds
  segment_size_threshold: 128 * 1024 * 1024,  # 128 MB
  segment_time_threshold: 3600,                # 1 hour

  # Conservative compaction schedule
  compaction_enabled: true,
  compaction_interval: 3_600_000,  # 1 hour
  compaction_min_segments: 4,

  # Keep more snapshots in production
  snapshot_retention: 10,

  # Production logging level
  log_level: :info
