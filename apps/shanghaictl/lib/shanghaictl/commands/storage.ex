defmodule Shanghaictl.Commands.Storage do
  @moduledoc """
  Storage command: reports a WAL/storage overview from the Admin API.
  """

  alias Shanghaictl.Format

  @doc """
  Shows a storage subsystem overview. Supports `--admin-url URL` and
  `--format json`.
  """
  def run(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)
    format = Shanghaictl.Options.format(opts)

    case fetch(admin_url) do
      {:ok, storage} -> render(storage, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/api/v1/storage") do
      {:ok, %{status: 200, body: %{"durable" => _} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp render(storage, :json), do: IO.puts(Jason.encode!(storage))

  defp render(storage, :text) do
    storage
    |> storage_lines()
    |> Enum.each(&IO.puts/1)
  end

  @doc false
  @spec storage_lines(map()) :: [String.t()]
  def storage_lines(storage) do
    [
      "Storage:",
      "  Durable: #{format_bool(Map.get(storage, "durable"))}",
      "  Segments: #{Map.get(storage, "active_segments")}",
      "  Entries: #{Map.get(storage, "entries")}",
      "  Size: #{format_bytes(Map.get(storage, "bytes"))}",
      "  Snapshots: #{Map.get(storage, "snapshots")}",
      "  Compaction Running: #{format_bool(Map.get(storage, "compaction_running"))}"
    ]
  end

  defp format_bool(value) when is_boolean(value), do: Format.yes_no(value)
  defp format_bool(other), do: "#{other}"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: Format.bytes(bytes)
  defp format_bytes(other), do: "#{other}"

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
