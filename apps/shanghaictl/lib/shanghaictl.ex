defmodule Shanghaictl do
  @moduledoc """
  Command-line interface for Shanghai distributed database.

  Provides administrative and operational commands for managing
  Shanghai clusters, nodes, and replication.
  """

  alias Shanghaictl.Commands.{Kv, Metrics, Node, Replicas, Shutdown, Status}

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
          | {:kv_get, [String.t()]}
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
  def parse(["replicas" | opts]), do: {:replicas, opts}
  def parse(["metrics" | opts]), do: {:metrics, opts}
  def parse(["node", "join" | opts]), do: {:node_join, opts}
  def parse(["node", "leave" | opts]), do: {:node_leave, opts}
  def parse(["kv", "get" | opts]), do: {:kv_get, opts}
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
      replicas          Show replication groups and their status
      metrics           Show performance and operational metrics
      node join <id>    Add a node to the cluster
      node leave <id>   Remove a node from the cluster
      kv get <key>      Read a value from the store by key
      shutdown          Safely shutdown a node

    For more information, see the documentation.
    """)
  end

  defp execute({:status, opts}) do
    Status.run(opts)
  end

  defp execute({:replicas, opts}) do
    Replicas.run(opts)
  end

  defp execute({:metrics, opts}) do
    Metrics.run(opts)
  end

  defp execute({:node_join, opts}) do
    Node.join(opts)
  end

  defp execute({:node_leave, opts}) do
    Node.leave(opts)
  end

  defp execute({:kv_get, opts}) do
    Kv.get(opts)
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
