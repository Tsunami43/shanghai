defmodule AdminApi.Plugs.RequestLogger do
  @moduledoc """
  Plug that emits a structured log line for each HTTP request once the response
  is sent, including the method, path, status and duration. The correlation id
  set by `AdminApi.Plugs.CorrelationId` is attached automatically by the logger.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time()

    register_before_send(conn, fn conn ->
      duration_ms =
        System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

      Observability.Logger.info("admin_api request", log_fields(conn, duration_ms))
      conn
    end)
  end

  @doc false
  @spec log_fields(Plug.Conn.t(), non_neg_integer()) :: keyword()
  def log_fields(conn, duration_ms) do
    [
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      duration_ms: duration_ms
    ]
  end
end
