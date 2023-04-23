import Config

# Replication tests start their own Replication.Monitor with custom settings,
# so the application must not auto-start the shared one under the test env.
config :replication, start_monitor: false
