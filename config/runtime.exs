import Config

# Runtime configuration, evaluated at boot for every environment (including
# releases). Operators override paths and ports here via environment variables.

# Enable the durable storage stack (WAL writer/reader, snapshots, compaction
# scheduler) outside the test environment. Storage.Supervisor only starts the
# full stack when `:data_root` is set; without it, the node runs in the
# in-memory-only mode. Tests manage their own WAL infrastructure and rely on the
# in-memory mode, so `:data_root` is deliberately left unset under `:test`.
if config_env() != :test do
  data_root =
    System.get_env("SHANGHAI_DATA_DIR") ||
      Path.join(System.tmp_dir!(), "shanghai")

  config :storage, data_root: data_root
end
