defmodule Shanghaictl.Commands.Status do
  @moduledoc """
  Status command for inspecting cluster health.
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Shows cluster status including nodes and their states.
  """
  def run(opts \\ []) do
    IO.puts("Shanghai Cluster Status")
    IO.puts(String.duplicate("=", 40))
    IO.puts("")

    admin_url = Keyword.get(opts, :admin_url, @default_admin_url)

    case get_cluster_info(admin_url) do
      {:ok, info} -> display_cluster_info(info)
      {:error, :not_connected} -> display_not_connected()
      {:error, reason} -> display_error(reason)
    end
  end

  defp get_cluster_info(admin_url) do
    with {:ok, %{status: 200, body: %{"nodes" => nodes}}} <-
           Req.get("#{admin_url}/api/v1/nodes"),
         {:ok, %{status: 200, body: %{"cluster_state" => state}}} <-
           Req.get("#{admin_url}/api/v1/status") do
      {:ok,
       %{
         nodes: Enum.map(nodes, &parse_node/1),
         cluster_state: String.to_atom(state)
       }}
    else
      {:ok, %{status: status}} ->
        {:error, "API returned status #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, :not_connected}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_node(node) do
    %{
      id: node["id"],
      status: String.to_atom(node["status"]),
      heartbeat_age: node["heartbeat_age_ms"]
    }
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

  defp display_error(reason) do
    IO.puts("Error: #{reason}")
    System.halt(1)
  end

  defp format_state(:healthy), do: "Healthy"
  defp format_state(:degraded), do: "Degraded"
  defp format_state(:unavailable), do: "Unavailable"
end
