defmodule Shanghaictl.Commands.Snapshot do
  @moduledoc """
  Snapshot commands: list persisted snapshots and create new ones via the Admin API.
  """

  @doc "Lists persisted snapshots, one per line."
  def list(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)

    case fetch_list(admin_url) do
      {:ok, []} -> IO.puts("(no snapshots)")
      {:ok, snapshots} -> Enum.each(snapshots, &IO.puts(snapshot_line(&1)))
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  @doc "Creates a snapshot at the current LSN."
  def create(opts \\ []) do
    admin_url = Shanghaictl.Options.admin_url(opts)

    case request_create(admin_url) do
      {:ok, id} -> IO.puts("Snapshot created: #{id}")
      {:error, :not_running} -> not_running()
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  @doc false
  @spec snapshot_line(map()) :: String.t()
  def snapshot_line(snapshot) when is_map(snapshot) do
    id = Map.get(snapshot, "id", "?")
    lsn = Map.get(snapshot, "lsn")
    if lsn, do: "#{id} (lsn: #{lsn})", else: to_string(id)
  end

  defp fetch_list(admin_url) do
    case Req.get("#{admin_url}/api/v1/snapshots") do
      {:ok, %{status: 200, body: %{"snapshots" => snapshots}}} -> {:ok, snapshots}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp request_create(admin_url) do
    case Req.post("#{admin_url}/api/v1/snapshots", json: %{}) do
      {:ok, %{status: 201, body: %{"snapshot_id" => id}}} -> {:ok, id}
      {:ok, %{status: 503}} -> {:error, :not_running}
      {:ok, %{status: status}} -> {:error, "API returned status #{status}"}
      {:error, %{reason: :econnrefused}} -> {:error, :not_connected}
      {:error, reason} -> {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp not_running do
    IO.puts("Snapshots are not configured on this node.")
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
