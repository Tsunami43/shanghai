defmodule Shanghaictl.Commands.Kv do
  @moduledoc """
  Key/value command for reading values from the store over the Admin API.
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Reads a single key. Expects `[key | opts]`; supports `--admin-url URL`.
  """
  def get([]) do
    IO.puts("Error: missing key")
    IO.puts("Usage: shanghaictl kv get <key> [--admin-url URL]")
    System.halt(1)
  end

  def get([key | opts]) do
    admin_url = admin_url(opts)

    case fetch(admin_url, key) do
      {:ok, value} -> IO.puts(format_value(value))
      {:error, :not_found} -> not_found(key)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url, key) do
    case Req.get("#{admin_url}/api/v1/kv/#{URI.encode(key)}") do
      {:ok, %{status: 200, body: %{"value" => value}}} -> {:ok, value}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp admin_url(opts) do
    case opts do
      ["--admin-url", url | _rest] -> url
      _ -> @default_admin_url
    end
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp not_found(key) do
    IO.puts("Key not found: #{key}")
    System.halt(1)
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
