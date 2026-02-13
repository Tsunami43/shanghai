defmodule Shanghaictl.Commands.Namespaces do
  @moduledoc """
  Namespaces command: reports the per-namespace count of live (`:up`) nodes from
  the Admin API.
  """

  @doc """
  Shows the per-namespace up-node counts. Supports `--admin-url URL` and
  `--format json`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case fetch(admin_url) do
      {:ok, body} -> render(body, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/api/v1/namespaces") do
      {:ok, %{status: 200, body: %{"namespaces" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp render(body, :json), do: IO.puts(Jason.encode!(body))

  defp render(body, :text) do
    body
    |> namespace_lines()
    |> Enum.each(&IO.puts/1)
  end

  @doc false
  @spec namespace_lines(map()) :: [String.t()]
  def namespace_lines(body) do
    namespaces = Map.get(body, "namespaces", %{})

    header = ["Namespaces: #{Map.get(body, "count", map_size(namespaces))}"]

    rows =
      namespaces
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {namespace, up} -> "  - #{namespace}: #{up} up" end)

    header ++ rows
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
