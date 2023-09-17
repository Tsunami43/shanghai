defmodule AdminApi.Plugs.RequestLoggerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias AdminApi.Plugs.RequestLogger

  test "log_fields/2 captures method, path, status and duration" do
    conn =
      :get
      |> conn("/health")
      |> Map.put(:status, 200)

    fields = RequestLogger.log_fields(conn, 7)

    assert fields[:method] == "GET"
    assert fields[:path] == "/health"
    assert fields[:status] == 200
    assert fields[:duration_ms] == 7
  end

  test "call/2 passes the request through and logs on send" do
    conn =
      :get
      |> conn("/health")
      |> RequestLogger.call([])
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end
