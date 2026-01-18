import Config

# Storage application configuration
#
# This file contains default configuration that is loaded in all environments.
# Environment-specific overrides can be found in config/{env}.exs files.

# Default storage configuration
# Override this in environment-specific configs or at runtime
config :storage,
  # Root directory for all storage data
  # Set to nil to disable automatic startup of storage components
  data_root: nil,

  # Node identifier for this storage instance
  node_id: "node_1",

  # WAL segment rotation thresholds
  # Segments rotate when EITHER threshold is met (hybrid strategy)
  # 64 MB
  segment_size_threshold: 64 * 1024 * 1024,
  # 1 hour (in seconds)
  segment_time_threshold: 3600,

  # Index configuration
  # Flush to disk every N inserts
  index_flush_threshold: 1000,
  # Or every N milliseconds
  index_flush_interval: 10_000,

  # Snapshot configuration
  # Keep N most recent snapshots
  snapshot_retention: 5,
  # Compression algorithm
  snapshot_compression: :gzip,

  # Compaction configuration
  compaction_enabled: true,
  # 1 hour in milliseconds
  compaction_interval: 3_600_000,
  compaction_strategy: Storage.Compaction.Strategy.SizeTiered,
  # Minimum segments to trigger compaction
  compaction_min_segments: 4,

  # Compaction strategy: Size-Tiered thresholds
  compaction_tier_thresholds: [
    # 16 MB
    16 * 1024 * 1024,
    # 64 MB
    64 * 1024 * 1024,
    # 256 MB
    256 * 1024 * 1024
  ]

# Import environment-specific config
# This must remain at the bottom of this file
import_config "#{config_env()}.exs"
