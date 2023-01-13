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
  segment_size_threshold: 64 * 1024 * 1024,  # 64 MB
  segment_time_threshold: 3600,               # 1 hour (in seconds)

  # Index configuration
  index_flush_threshold: 1000,     # Flush to disk every N inserts
  index_flush_interval: 10_000,    # Or every N milliseconds

  # Snapshot configuration
  snapshot_retention: 5,            # Keep N most recent snapshots
  snapshot_compression: :gzip,      # Compression algorithm

  # Compaction configuration
  compaction_enabled: true,
  compaction_interval: 3_600_000,   # 1 hour in milliseconds
  compaction_strategy: Storage.Compaction.Strategy.SizeTiered,
  compaction_min_segments: 4,       # Minimum segments to trigger compaction

  # Compaction strategy: Size-Tiered thresholds
  compaction_tier_thresholds: [
    16 * 1024 * 1024,   # 16 MB
    64 * 1024 * 1024,   # 64 MB
    256 * 1024 * 1024   # 256 MB
  ]

# Import environment-specific config
# This must remain at the bottom of this file
import_config "#{config_env()}.exs"
