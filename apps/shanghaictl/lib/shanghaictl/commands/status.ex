defmodule Shanghaictl.Commands.Status do
  @moduledoc """
  Status command for inspecting cluster health.
  """

  @doc """
  Shows cluster status including nodes and their states.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case get_cluster_info(admin_url) do
      {:ok, info} -> render(info, format)
      {:error, :not_connected} -> display_not_connected()
      {:error, reason} -> display_error(reason)
    end
  end

  defp render(info, :json), do: IO.puts(to_json(info))

  defp render(info, :text) do
    IO.puts("Shanghai Cluster Status")
    IO.puts(String.duplicate("=", 40))
    IO.puts("")
    display_cluster_info(info)
  end

  @doc false
  @spec to_json(map()) :: String.t()
  def to_json(info) do
    Jason.encode!(%{
      cluster_state: to_string(info.cluster_state),
      local_node_id: info.local_node_id,
      quorum_available: info.quorum_available,
      quorum_size: info.quorum_size,
      nodes:
        Enum.map(info.nodes, fn node ->
          %{
            id: node.id,
            status: to_string(node.status),
            heartbeat_age_ms: node.heartbeat_age
          }
        end)
    })
  end

  defp get_cluster_info(admin_url) do
    with {:ok, %{status: 200, body: %{"nodes" => nodes}}} <-
           Req.get("#{admin_url}/api/v1/nodes"),
         {:ok, %{status: 200, body: %{"cluster_state" => state} = status}} <-
           Req.get("#{admin_url}/api/v1/status") do
      {:ok,
       %{
         nodes: Enum.map(nodes, &parse_node/1),
         cluster_state: String.to_atom(state),
         local_node_id: status["local_node_id"],
         quorum_available: status["quorum_available"],
         quorum_size: status["quorum_size"]
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

  @doc false
  @spec local_node_line(String.t() | nil) :: String.t() | nil
  def local_node_line(nil), do: nil
  def local_node_line(id), do: "Local Node:    #{id}"

  @doc false
  @spec quorum_line(boolean() | nil, non_neg_integer() | nil) :: String.t() | nil
  def quorum_line(nil, _size), do: nil
  def quorum_line(true, size), do: "Quorum:        available#{quorum_needed(size)}"
  def quorum_line(false, size), do: "Quorum:        unavailable#{quorum_needed(size)}"

  defp quorum_needed(nil), do: ""
  defp quorum_needed(size), do: " (#{size} needed)"

  defp display_cluster_info(info) do
    IO.puts("Cluster State: #{format_state(info.cluster_state)}")

    if line = local_node_line(info.local_node_id), do: IO.puts(line)
    if line = quorum_line(info.quorum_available, info.quorum_size), do: IO.puts(line)

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
