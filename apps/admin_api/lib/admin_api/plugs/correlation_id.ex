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
    correlation_id = extract_or_generate_correlation_id(conn)

    # Set in process dictionary for logging
    Observability.Logger.put_correlation_id(correlation_id)

    # Add to response headers
    conn
    |> put_resp_header(@correlation_header, correlation_id)
    |> put_private(:correlation_id, correlation_id)
  end

  defp extract_or_generate_correlation_id(conn) do
    case get_req_header(conn, @correlation_header) do
      [correlation_id | _] -> correlation_id
      [] -> Observability.Logger.new_correlation_id()
    end
  end
end
