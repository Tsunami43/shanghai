defmodule Shanghaictl do
  @moduledoc """
  Command-line interface for Shanghai distributed database.

  Provides administrative and operational commands for managing
  Shanghai clusters, nodes, and replication.
  """

  alias Shanghaictl.Commands.{
    Compact,
    Config,
    Health,
    Info,
    Kv,
    Metrics,
    Namespaces,
    Node,
    Replicas,
    Shutdown,
    Snapshot,
    Status,
    Storage,
    Topology
  }

  @doc """
  Main entry point for the CLI.
  """
  def main(args \\ []) do
    args
    |> parse()
    |> execute()
  end

  @typedoc "A parsed CLI command."
  @type command ::
          :help
          | :version
          | {:status | :replicas | :metrics | :node_join | :node_leave | :shutdown, [String.t()]}
          | {:health | :info | :config | :compact | :namespaces, [String.t()]}
          | {:node_get | :kv_get | :kv_count | :kv_keys, [String.t()]}
          | {:snapshot_create | :snapshot_list, [String.t()]}
          | {:unknown, [String.t()]}

  @doc """
  Parses raw CLI arguments into a command. Pure and side-effect free.

  ## Examples

      iex> Shanghaictl.parse(["status", "--json"])
      {:status, ["--json"]}

      iex> Shanghaictl.parse(["bogus"])
      {:unknown, ["bogus"]}
  """
  @spec parse([String.t()]) :: command()
  def parse([]), do: :help
  def parse(["help"]), do: :help
  def parse(["version"]), do: :version
  def parse(["status" | opts]), do: {:status, opts}
  def parse(["health" | opts]), do: {:health, opts}
  def parse(["info" | opts]), do: {:info, opts}
  def parse(["compact" | opts]), do: {:compact, opts}
  def parse(["config" | opts]), do: {:config, opts}
  def parse(["snapshot", "create" | opts]), do: {:snapshot_create, opts}
  def parse(["snapshot", "list" | opts]), do: {:snapshot_list, opts}
  def parse(["replicas" | opts]), do: {:replicas, opts}
  def parse(["metrics" | opts]), do: {:metrics, opts}
  def parse(["storage" | opts]), do: {:storage, opts}
  def parse(["topology" | opts]), do: {:topology, opts}
  def parse(["namespaces" | opts]), do: {:namespaces, opts}
  def parse(["node", "join" | opts]), do: {:node_join, opts}
  def parse(["node", "leave" | opts]), do: {:node_leave, opts}
  def parse(["node", "get" | opts]), do: {:node_get, opts}
  def parse(["kv", "get" | opts]), do: {:kv_get, opts}
  def parse(["kv", "exists" | opts]), do: {:kv_exists, opts}
  def parse(["kv", "count" | opts]), do: {:kv_count, opts}
  def parse(["kv", "keys" | opts]), do: {:kv_keys, opts}
  def parse(["shutdown" | opts]), do: {:shutdown, opts}
  def parse(args), do: {:unknown, args}

  defp execute(:help) do
    IO.puts("""
    Shanghai Control Tool (shanghaictl)

    Usage:
      shanghaictl <command> [options]

    Commands:
      help              Show this help message
      version           Show version information
      status            Show cluster status and node health
      health            Show node readiness and subsystem checks
      info              Show node version and runtime details
      config            Show effective runtime configuration
      replicas          Show replication groups and their status
      metrics           Show performance and operational metrics
      storage           Show a WAL/storage overview
      topology          Show the cluster topology
      namespaces        Show per-namespace live node counts
      node join <id>    Add a node to the cluster
      node leave <id>   Remove a node from the cluster
      node get <id>     Show details for a single node
      kv get <key>      Read a value from the store by key
      kv exists <key>   Report whether a key exists (true/false)
      kv count [prefix] Count stored keys (optionally under a prefix)
      kv keys [prefix]  List stored keys (optionally under a prefix)
      compact           Trigger a WAL compaction run
      snapshot list     List persisted snapshots
      snapshot create   Create a snapshot at the current LSN
      shutdown          Safely shutdown a node

    For more information, see the documentation.
    """)
  end

  defp execute({:status, opts}) do
    Status.run(opts)
  end

  defp execute({:health, opts}) do
    Health.run(opts)
  end

  defp execute({:info, opts}) do
    Info.run(opts)
  end

  defp execute({:config, opts}) do
    Config.run(opts)
  end

  defp execute({:compact, opts}) do
    Compact.run(opts)
  end

  defp execute({:snapshot_create, opts}) do
    Snapshot.create(opts)
  end

  defp execute({:snapshot_list, opts}) do
    Snapshot.list(opts)
  end

  defp execute({:replicas, opts}) do
    Replicas.run(opts)
  end

  defp execute({:metrics, opts}) do
    Metrics.run(opts)
  end

  defp execute({:storage, opts}) do
    Storage.run(opts)
  end

  defp execute({:topology, opts}) do
    Topology.run(opts)
  end

  defp execute({:namespaces, opts}) do
    Namespaces.run(opts)
  end

  defp execute({:node_join, opts}) do
    Node.join(opts)
  end

  defp execute({:node_leave, opts}) do
    Node.leave(opts)
  end

  defp execute({:node_get, opts}) do
    Node.get(opts)
  end

  defp execute({:kv_get, opts}) do
    Kv.get(opts)
  end

  defp execute({:kv_exists, opts}) do
    Kv.exists(opts)
  end

  defp execute({:kv_count, opts}) do
    Kv.count(opts)
  end

  defp execute({:kv_keys, opts}) do
    Kv.keys(opts)
  end

  defp execute({:shutdown, opts}) do
    Shutdown.run(opts)
  end

  defp execute(:version) do
    {:ok, vsn} = :application.get_key(:shanghaictl, :vsn)
    IO.puts("shanghaictl version #{vsn}")
  end

  defp execute({:unknown, args}) do
    IO.puts("Unknown command: #{Enum.join(args, " ")}")
    IO.puts("Run 'shanghaictl help' for usage information.")
    System.halt(1)
  end
end
