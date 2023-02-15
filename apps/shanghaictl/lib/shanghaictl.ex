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
  defp parse_args(args), do: {:unknown, args}

  defp execute(:help) do
    IO.puts("""
    Shanghai Control Tool (shanghaictl)

    Usage:
      shanghaictl <command> [options]

    Commands:
      help          Show this help message
      version       Show version information

    For more information, see the documentation.
    """)
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
