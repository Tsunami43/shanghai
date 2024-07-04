defmodule Shanghaictl.Commands.Topology do
  @moduledoc """
  Topology command: reports the cluster topology snapshot from the Admin API.
  """

  @doc """
  Shows the cluster topology. Supports `--admin-url URL` and `--format json`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case fetch(admin_url) do
      {:ok, topology} -> render(topology, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/api/v1/topology") do
      {:ok, %{status: 200, body: %{"nodes" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp render(topology, :json), do: IO.puts(Jason.encode!(topology))

  defp render(topology, :text) do
    topology
    |> topology_lines()
    |> Enum.each(&IO.puts/1)
  end

  @doc false
  @spec topology_lines(map()) :: [String.t()]
  def topology_lines(topology) do
    summary = Map.get(topology, "status_summary", %{})

    header = [
      "Topology:",
      "  Local Node: #{Map.get(topology, "local_node_id")}",
      "  Nodes: #{Map.get(topology, "node_count")}" <>
        " (up #{Map.get(summary, "up", 0)}," <>
        " suspect #{Map.get(summary, "suspect", 0)}," <>
        " down #{Map.get(summary, "down", 0)})"
    ]

    node_lines =
      topology
      |> Map.get("nodes", [])
      |> Enum.map(fn node ->
        "    - #{Map.get(node, "id")} @ #{Map.get(node, "address")} [#{Map.get(node, "status")}]"
      end)

    header ++ node_lines
  end

  defp not_connected do
    IO.puts("Error: Not connected to cluster")
    IO.puts("Ensure Shanghai node is running and accessible.")
    System.halt(1)
  end

  defp error(reason) do
    IO.puts("Error: #{reason}")
    System.halt(1)
  end
end
