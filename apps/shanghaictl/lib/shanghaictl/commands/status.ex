defmodule Shanghaictl.Commands.Status do
  @moduledoc """
  Status command for inspecting cluster health.
  """

  @doc """
  Shows cluster status including nodes and their states.
  """
  def run(_opts \\ []) do
    IO.puts("Shanghai Cluster Status")
    IO.puts(String.duplicate("=", 40))
    IO.puts("")

    case get_cluster_info() do
      {:ok, info} -> display_cluster_info(info)
      {:error, :not_connected} -> display_not_connected()
    end
  end

  defp get_cluster_info do
    # In real implementation, would connect to admin API
    # For now, return mock data
    {:ok,
     %{
       nodes: [
         %{id: "node-1", status: :up, heartbeat_age: 100},
         %{id: "node-2", status: :up, heartbeat_age: 150},
         %{id: "node-3", status: :suspect, heartbeat_age: 3000}
       ],
       cluster_state: :healthy
     }}
  end

  defp display_cluster_info(info) do
    IO.puts("Cluster State: #{format_state(info.cluster_state)}")
    IO.puts("")
    IO.puts("Nodes:")

    Enum.each(info.nodes, fn node ->
      status_icon = if node.status == :up, do: "✓", else: "✗"
      IO.puts("  #{status_icon} #{node.id} - #{node.status} (heartbeat: #{node.heartbeat_age}ms ago)")
    end)
  end

  defp display_not_connected do
    IO.puts("Error: Not connected to cluster")
    IO.puts("Ensure Shanghai node is running and accessible.")
    System.halt(1)
  end

  defp format_state(:healthy), do: "Healthy"
  defp format_state(:degraded), do: "Degraded"
  defp format_state(:unavailable), do: "Unavailable"
end
