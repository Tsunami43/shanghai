defmodule Shanghaictl do
  @moduledoc """
  Command-line interface for Shanghai distributed database.

  Provides administrative and operational commands for managing
  Shanghai clusters, nodes, and replication.
  """

  @doc """
  Main entry point for the CLI.
  """
  def main(args \\ []) do
    args
    |> parse_args()
    |> execute()
  end

  defp parse_args([]), do: :help
  defp parse_args(["help"]), do: :help
  defp parse_args(["version"]), do: :version
  defp parse_args(["status" | opts]), do: {:status, opts}
  defp parse_args(["replicas" | opts]), do: {:replicas, opts}
  defp parse_args(["metrics" | opts]), do: {:metrics, opts}
  defp parse_args(["node", "join" | opts]), do: {:node_join, opts}
  defp parse_args(["node", "leave" | opts]), do: {:node_leave, opts}
  defp parse_args(["shutdown" | opts]), do: {:shutdown, opts}
  defp parse_args(args), do: {:unknown, args}

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
      shutdown          Safely shutdown a node

    For more information, see the documentation.
    """)
  end

  defp execute({:status, opts}) do
    Shanghaictl.Commands.Status.run(opts)
  end

  defp execute({:replicas, opts}) do
    Shanghaictl.Commands.Replicas.run(opts)
  end

  defp execute({:metrics, opts}) do
    Shanghaictl.Commands.Metrics.run(opts)
  end

  defp execute({:node_join, opts}) do
    Shanghaictl.Commands.Node.join(opts)
  end

  defp execute({:node_leave, opts}) do
    Shanghaictl.Commands.Node.leave(opts)
  end

  defp execute({:shutdown, opts}) do
    Shanghaictl.Commands.Shutdown.run(opts)
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
