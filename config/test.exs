import Config

# Replication tests start their own Replication.Monitor with custom settings,
# so the application must not auto-start the shared one under the test env.
config :replication, start_monitor: false

# Replication.Epoch is a named singleton owning a named ETS table, so tests that
# need to restart it (to prove a vote survives) cannot do that to an
# application-owned one without taking the supervisor down with it. Tests start
# their own.
config :replication, start_epoch: false
