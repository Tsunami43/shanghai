import Config

# Query read-cache tuning. Both keys are optional; these are the defaults.
# See docs/TUNING.md for guidance.
#
#     config :query, :cache,
#       max_size: 10_000,   # Max cached keys before FIFO eviction
#       ttl_ms: nil         # Entry time-to-live in ms, or nil for no expiry

# Import environment specific config.
#
# Resolve the path relative to THIS file (not the current working directory) so
# the env config is loaded reliably whether Mix runs from the umbrella root or
# from an individual app directory (e.g. `cd apps/foo && mix test`).
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
