defmodule Shanghaictl.Commands.Replicas do
  @moduledoc """
  Replicas command for inspecting replication groups.
  """

  @doc """
  Shows replication group status including leaders and followers.
  """
  def run(opts \\ []) do
    IO.puts("Shanghai Replication Groups")
    IO.puts(String.duplicate("=", 40))
    IO.puts("")

    admin_url = Shanghaictl.Options.admin_url(opts)

    case get_replicas_info(admin_url) do
      {:ok, body} -> display(body)
      {:error, :not_connected} -> display_not_connected()
      {:error, reason} -> display_error(reason)
    end
  end

  defp get_replicas_info(admin_url) do
    case Req.get("#{admin_url}/api/v1/replicas") do
      {:ok, %{status: 200, body: %{"replicas" => _replicas} = body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "API returned status #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, :not_connected}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp display(body) do
    display_replicas(body["replicas"])

    if line = summary_line(body["summary"]), do: IO.puts(line)
  end

  @doc false
  @spec summary_line(map() | nil) :: String.t() | nil
  def summary_line(nil), do: nil

  def summary_line(summary) when is_map(summary) do
    "Summary: #{summary["groups"]} group(s), #{summary["replicas"]} replica(s), " <>
      "#{summary["lagging"]} lagging, #{summary["stale"]} stale"
  end

  defp display_replicas(replicas) when is_list(replicas) do
    if replicas == [] do
      IO.puts("No replication groups found.")
    else
      Enum.each(replicas, &display_replica_group/1)
    end
  end

  defp display_replica_group(group) do
    IO.puts("Group: #{group["group_id"]}")
    IO.puts("  Leader: #{group["leader_id"]} (offset: #{group["current_offset"]})")
    IO.puts("  Followers:")

    Enum.each(group["followers"], fn follower ->
      status_icon = if follower["status"] == "healthy", do: "✓", else: "⚠"

      IO.puts(
        "    #{status_icon} #{follower["node_id"]} - offset: #{follower["offset"]}, lag: #{follower["lag"]} (#{follower["status"]})"
      )
    end)

    IO.puts("")
  end

  defp display_not_connected do
    IO.puts("Error: Not connected to cluster")
    IO.puts("Ensure Shanghai node is running and accessible.")
    System.halt(1)
  end

  defp display_error(reason) do
    IO.puts("Error: #{reason}")
    System.halt(1)
  end
end
