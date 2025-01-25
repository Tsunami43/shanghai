defmodule Shanghaictl.Commands.Node do
  @moduledoc """
  Node management commands for joining and leaving the cluster.
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Adds a node to the cluster.
  """
  def join([node_id | opts]) when is_binary(node_id) do
    admin_url = extract_admin_url(opts)
    {host, port} = extract_node_address(opts)

    IO.puts("Adding node #{node_id} (#{host}:#{port}) to cluster...")

    case request_node_join(admin_url, node_id, host, port) do
      {:ok, _response} ->
        IO.puts("Successfully added node #{node_id}")

      {:error, reason} ->
        IO.puts("Failed to add node: #{reason}")
        System.halt(1)
    end
  end

  def join(_) do
    IO.puts("Usage: shanghaictl node join <node-id> [--host=<host>] [--port=<port>]")
    System.halt(1)
  end

  @doc """
  Removes a node from the cluster.
  """
  def leave([node_id | opts]) when is_binary(node_id) do
    admin_url = extract_admin_url(opts)

    IO.puts("Removing node #{node_id} from cluster...")

    case request_node_leave(admin_url, node_id) do
      {:ok, _response} ->
        IO.puts("Successfully removed node #{node_id}")

      {:error, reason} ->
        IO.puts("Failed to remove node: #{reason}")
        System.halt(1)
    end
  end

  def leave(_) do
    IO.puts("Usage: shanghaictl node leave <node-id>")
    System.halt(1)
  end

  defp extract_admin_url(opts) do
    Enum.find_value(opts, @default_admin_url, fn
      "--admin-url=" <> url -> url
      _ -> nil
    end)
  end

  defp extract_node_address(opts) do
    host = Enum.find_value(opts, "localhost", fn
      "--host=" <> h -> h
      _ -> nil
    end)

    port = Enum.find_value(opts, 4000, fn
      "--port=" <> p -> String.to_integer(p)
      _ -> nil
    end)

    {host, port}
  end

  defp request_node_join(admin_url, node_id, host, port) do
    case Req.post("#{admin_url}/api/v1/nodes", json: %{id: node_id, action: "join", host: host, port: port}) do
      {:ok, %{status: 200}} ->
        {:ok, :joined}

      {:ok, %{status: status}} ->
        {:error, "API returned status #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, "Cannot connect to Admin API at #{admin_url}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp request_node_leave(admin_url, node_id) do
    case Req.post("#{admin_url}/api/v1/nodes", json: %{id: node_id, action: "leave"}) do
      {:ok, %{status: 200}} ->
        {:ok, :left}

      {:ok, %{status: status}} ->
        {:error, "API returned status #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, "Cannot connect to Admin API at #{admin_url}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
end
