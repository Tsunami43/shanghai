defmodule Shanghaictl.Commands.Shutdown do
  @moduledoc """
  Shutdown command for safely shutting down a Shanghai node.
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Safely shuts down a Shanghai node.
  """
  def run(opts \\ []) do
    admin_url = extract_admin_url(opts)
    force = Enum.member?(opts, "--force")
    timeout = extract_timeout(opts)

    if force do
      IO.puts("Initiating forced shutdown...")
    else
      IO.puts("Initiating graceful shutdown (timeout: #{timeout}s)...")
      IO.puts("Use --force to skip graceful shutdown.")
    end

    case request_shutdown(admin_url, force, timeout) do
      {:ok, _response} ->
        IO.puts("Shutdown initiated successfully.")

      {:error, :not_connected} ->
        IO.puts("Error: Cannot connect to Admin API at #{admin_url}")
        IO.puts("Node may already be down.")
        System.halt(1)

      {:error, reason} ->
        IO.puts("Failed to shutdown: #{reason}")
        System.halt(1)
    end
  end

  defp extract_admin_url(opts) do
    Enum.find_value(opts, @default_admin_url, fn
      "--admin-url=" <> url -> url
      _ -> nil
    end)
  end

  defp extract_timeout(opts) do
    Enum.find_value(opts, 30, fn
      "--timeout=" <> t -> String.to_integer(t)
      _ -> nil
    end)
  end

  defp request_shutdown(admin_url, force, timeout) do
    params = %{
      force: force,
      timeout_seconds: timeout
    }

    case Req.post("#{admin_url}/api/v1/shutdown", json: params) do
      {:ok, %{status: 200}} ->
        {:ok, :shutdown_initiated}

      {:ok, %{status: 202}} ->
        {:ok, :shutdown_in_progress}

      {:ok, %{status: status, body: body}} ->
        error_msg = if is_map(body), do: body["error"], else: "status #{status}"
        {:error, error_msg || "unknown error"}

      {:error, %{reason: :econnrefused}} ->
        {:error, :not_connected}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
end
