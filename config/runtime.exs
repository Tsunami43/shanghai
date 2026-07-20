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

  # Leadership epochs and votes must survive a restart, otherwise a node can
  # vote twice in one epoch and two leaders can be elected in it. Defaults
  # under the same data root; override to place it on its own volume.
  config :replication,
    epoch_dir:
      System.get_env("SHANGHAI_EPOCH_DIR") ||
        Path.join([data_root, "replication", "epochs"])

  # Seed nodes for Erlang-distribution discovery, from a comma-separated list of
  # `name@host` entries (e.g. "node-1@10.0.1.10,node-2@10.0.1.11").
  seed_nodes =
    "SHANGHAI_CLUSTER_NODES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :cluster, seed_nodes: seed_nodes
end
