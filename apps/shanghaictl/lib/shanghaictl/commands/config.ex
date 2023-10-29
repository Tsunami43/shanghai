defmodule Shanghaictl.Commands.Config do
  @moduledoc """
  Config command: shows the node's effective runtime configuration.
  """

  @doc """
  Shows the effective configuration. Supports `--admin-url URL` and
  `--format json`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case fetch(admin_url) do
      {:ok, config} -> render(config, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/api/v1/config") do
      {:ok, %{status: 200, body: %{"cache" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp render(config, :json), do: IO.puts(Jason.encode!(config))

  defp render(config, :text) do
    config
    |> config_lines()
    |> Enum.each(&IO.puts/1)
  end

  @doc false
  @spec config_lines(map()) :: [String.t()]
  def config_lines(config) do
    cache = Map.get(config, "cache", %{})
    compaction = Map.get(config, "compaction", %{})

    [
      "Configuration:",
      "  Admin Port: #{Map.get(config, "admin_port")}",
      "  Cache:",
      "    Max Size: #{Map.get(cache, "max_size")}",
      "    TTL: #{format_ttl(Map.get(cache, "ttl_ms"))}",
      "  Compaction:",
      "    Running: #{Map.get(compaction, "running")}",
      "    Enabled: #{Map.get(compaction, "enabled")}"
    ]
  end

  defp format_ttl(nil), do: "none"
  defp format_ttl(ms), do: "#{ms}ms"

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
