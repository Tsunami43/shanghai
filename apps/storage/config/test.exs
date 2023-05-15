import Config

# Test environment configuration

# In test, do NOT set data_root - each test will configure its own storage
# This prevents automatic startup of storage components which would conflict with test setups
config :storage,
  data_root: nil,
  node_id: "test_node",

  # Fast rotation for testing
  segment_size_threshold: 1 * 1024 * 1024,  # 1 MB
  segment_time_threshold: 60,                # 1 minute

  # Disable automatic compaction in tests
  # Tests will trigger compaction manually when needed
  compaction_enabled: false,
  compaction_interval: 60_000,  # 1 minute (if enabled)

  # Minimal snapshot retention for tests
  snapshot_retention: 2
