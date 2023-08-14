defmodule Shanghaictl.Commands.Health do
  @moduledoc """
  Health command: reports node readiness from the Admin API `/ready` probe.
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Shows readiness and per-subsystem checks. Supports `--admin-url URL`.
  """
  def run(opts \\ []) do
    admin_url = admin_url(opts)
    format = output_format(opts)

    case fetch(admin_url) do
      {:ok, status, body} -> render(status, body, format)
      {:error, :not_connected} -> not_connected()
      {:error, reason} -> error(reason)
    end
  end

  defp output_format(opts) do
    json? =
      "--json" in opts or
        opts
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.any?(&(&1 == ["--format", "json"]))

    if json?, do: :json, else: :text
  end

  defp render(status, body, :json) do
    IO.puts(to_json(body))
    if status != 200, do: System.halt(1)
  end

  defp render(status, body, :text), do: display(status, body)

  @doc false
  @spec to_json(map()) :: String.t()
  def to_json(body), do: Jason.encode!(body)

  defp fetch(admin_url) do
    case Req.get("#{admin_url}/ready") do
      {:ok, %{status: status, body: %{"checks" => _} = body}} -> {:ok, status, body}
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

  defp display(status, body) do
    IO.puts("Readiness: #{body["status"]}")
    IO.puts("")
    IO.puts("Checks:")

    Enum.each(body["checks"], fn {name, up?} ->
      icon = if up?, do: "✓", else: "✗"
      IO.puts("  #{icon} #{name}")
    end)

    if status != 200, do: System.halt(1)
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
