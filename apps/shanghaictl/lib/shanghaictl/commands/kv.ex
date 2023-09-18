defmodule Shanghaictl.Commands.Kv do
  @moduledoc """
  Key/value command for reading values from the store over the Admin API.
  """

  @doc """
  Reads a single key. Expects `[key | opts]`; supports `--admin-url URL`.
  """
  def get([]) do
    IO.puts("Error: missing key")
    IO.puts("Usage: shanghaictl kv get <key> [--admin-url URL]")
    System.halt(1)
  end

  def get([key | opts]) do
    admin_url = Shanghaictl.Options.admin_url(opts)

    case fetch(admin_url, key) do
      {:ok, value} -> IO.puts(format_value(value))
      {:error, :not_found} -> not_found(key)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  @doc """
  Counts stored keys, optionally under a prefix. Expects `[]`, `[prefix]`, or
  options; supports `--admin-url URL`.
  """
  def count(args) do
    {prefix, opts} = split_prefix(args)
    admin_url = Shanghaictl.Options.admin_url(opts)

    case fetch_count(admin_url, prefix) do
      {:ok, n} -> IO.puts(to_string(n))
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp split_prefix(["--" <> _ | _] = opts), do: {nil, opts}
  defp split_prefix([prefix | opts]), do: {prefix, opts}
  defp split_prefix([]), do: {nil, []}

  @doc """
  Lists keys, optionally under a prefix. Prints one key per line.
  """
  def keys(args) do
    {prefix, opts} = split_prefix(args)
    admin_url = Shanghaictl.Options.admin_url(opts)

    case fetch_keys(admin_url, prefix) do
      {:ok, []} -> IO.puts("(no keys)")
      {:ok, keys} -> Enum.each(keys, &IO.puts/1)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch_keys(admin_url, prefix) do
    query = if prefix, do: "?prefix=#{URI.encode(prefix)}", else: ""

    case Req.get("#{admin_url}/api/v1/keys#{query}") do
      {:ok, %{status: 200, body: %{"keys" => keys}}} -> {:ok, keys}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp fetch_count(admin_url, prefix) do
    url =
      case prefix do
        nil -> "#{admin_url}/api/v1/kv"
        p -> "#{admin_url}/api/v1/kv?prefix=#{URI.encode(p)}"
      end

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"count" => count}}} -> {:ok, count}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
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
