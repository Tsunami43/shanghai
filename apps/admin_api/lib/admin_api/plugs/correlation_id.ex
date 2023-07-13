defmodule AdminApi.Plugs.CorrelationId do
  @moduledoc """
  Plug for extracting and propagating correlation IDs in HTTP requests.

  This plug:
  1. Extracts correlation ID from X-Correlation-ID header if present
  2. Generates a new correlation ID if not present
  3. Sets the correlation ID in the process dictionary
  4. Adds the correlation ID to the response headers
  """

  import Plug.Conn

  @correlation_header "x-correlation-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    correlation_id =
      case get_req_header(conn, @correlation_header) do
        # Honor a client-supplied id so traces span the request boundary.
        [correlation_id | _] ->
          Observability.Logger.put_correlation_id(correlation_id)
          correlation_id

        # Otherwise generate and store one for this request.
        [] ->
          Observability.Logger.ensure_correlation_id()
      end

    conn
    |> put_resp_header(@correlation_header, correlation_id)
    |> put_private(:correlation_id, correlation_id)
  end
end
