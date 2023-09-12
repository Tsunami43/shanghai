defmodule Shanghaictl.Commands.Info do
  @moduledoc """
  Info command: reports node version and runtime details from the Admin API.
  """

  @doc """
  Shows node/runtime information. Supports `--admin-url URL` and `--format json`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case fetch(admin_url) do
      {:ok, info} -> render(info, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/api/v1/info") do
      {:ok, %{status: 200, body: %{"version" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp render(info, :json), do: IO.puts(Jason.encode!(info))

  defp render(info, :text) do
    info
    |> info_lines()
    |> Enum.each(&IO.puts/1)
  end

  @doc false
  @spec info_lines(map()) :: [String.t()]
  def info_lines(info) do
    [
      "Node:    #{info["node_id"]}",
      "Version: #{info["version"]}",
      "Elixir:  #{info["elixir_version"]}",
      "OTP:     #{info["otp_release"]}"
    ]
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
