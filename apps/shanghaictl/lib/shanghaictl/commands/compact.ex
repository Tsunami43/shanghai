defmodule Shanghaictl.Commands.Compact do
  @moduledoc """
  Compact command: triggers a WAL compaction run via the Admin API.
  """

  @doc """
  Requests an immediate compaction run. Supports `--admin-url URL`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)

    case trigger(admin_url) do
      :ok -> IO.puts("Compaction triggered.")
      {:error, :not_running} -> not_running()
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp trigger(admin_url) do
    case Req.post("#{admin_url}/api/v1/compaction", json: %{}) do
      {:ok, %{status: 202}} -> :ok
      {:ok, %{status: 503}} -> {:error, :not_running}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp not_running do
    IO.puts("Compaction is not configured on this node.")
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
