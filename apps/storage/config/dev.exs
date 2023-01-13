import Config

# Development environment configuration

# In development, use a local directory for storage
config :storage,
  data_root: Path.expand("../../priv/storage_dev", __DIR__),
  node_id: "dev_node_1",

  # More aggressive rotation for testing
  segment_size_threshold: 10 * 1024 * 1024,  # 10 MB
  segment_time_threshold: 1800,               # 30 minutes

  # More frequent compaction in dev
  compaction_enabled: true,
  compaction_interval: 300_000,  # 5 minutes

  # Keep fewer snapshots in dev
  snapshot_retention: 3
