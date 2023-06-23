defmodule AdminApi.RouterTest do
  @moduledoc """
  Exercises the read-only Admin HTTP API endpoints against the live
  cluster/replication/observability processes started with the app.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  @opts AdminApi.Router.init([])

  setup_all do
    # The :cluster app intentionally omits its `mod:` callback under
    # MIX_ENV=test (so cluster's own tests control process startup), so a
    # downstream suite that needs a live cluster must start it explicitly.
    case Cluster.Application.start(:normal, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Replication.Monitor is not auto-started under the test env (see
    # config/test.exs); the /replicas and /metrics endpoints need it.
    case Replication.Monitor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp get(path) do
    :get
    |> conn(path)
    |> AdminApi.Router.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  test "GET /health returns ok" do
    conn = get("/health")
    assert conn.status == 200
    assert json(conn) == %{"status" => "ok"}
  end

  test "GET /ready reports readiness with per-process checks" do
    conn = get("/ready")
    assert conn.status == 200

    body = json(conn)
    assert body["status"] == "ready"
    assert body["checks"]["cluster_membership"] == true
    assert body["checks"]["replication_monitor"] == true
  end

  test "GET /api/v1/status reports cluster health fields" do
    conn = get("/api/v1/status")
    assert conn.status == 200

    body = json(conn)
    assert body["cluster_state"] in ["healthy", "degraded", "unavailable"]
    assert is_integer(body["node_count"])
    assert is_integer(body["nodes_up"])
    assert is_integer(body["timestamp"])
  end

  test "GET /api/v1/nodes returns a nodes list" do
    conn = get("/api/v1/nodes")
    assert conn.status == 200

    body = json(conn)
    assert is_list(body["nodes"])
  end

  test "GET /api/v1/replicas returns a replicas list" do
    conn = get("/api/v1/replicas")
    assert conn.status == 200

    body = json(conn)
    assert is_list(body["replicas"])
  end

  test "GET /api/v1/kv/:key returns a stored value" do
    {:ok, :written} = Query.write("admin-api:kv", "hello")

    conn = get("/api/v1/kv/admin-api:kv")
    assert conn.status == 200

    body = json(conn)
    assert body["key"] == "admin-api:kv"
    assert body["value"] == "hello"
  end

  test "GET /api/v1/kv/:key returns 404 for a missing key" do
    conn = get("/api/v1/kv/admin-api:absent")
    assert conn.status == 404
    assert json(conn)["error"] == "not_found"
  end

  test "GET /api/v1/metrics returns the metric sections" do
    conn = get("/api/v1/metrics")
    assert conn.status == 200

    body = json(conn)
    assert Map.has_key?(body, "wal")
    assert Map.has_key?(body, "replication")
    assert Map.has_key?(body, "heartbeat")
    assert Map.has_key?(body, "query")
  end

  test "sets an X-Correlation-ID response header" do
    conn = get("/health")
    assert [_correlation_id] = get_resp_header(conn, "x-correlation-id")
  end

  test "unknown routes return 404" do
    conn = get("/api/v1/nope")
    assert conn.status == 404
  end

  test "GET /metrics returns Prometheus text exposition format" do
    conn = get("/metrics")
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"

    body = conn.resp_body
    assert body =~ "# TYPE shanghai_wal_writes_total counter"
    assert body =~ "shanghai_wal_write_duration_ms_count"
    assert body =~ "# TYPE shanghai_cluster_heartbeat_rtt gauge"
    assert body =~ "# TYPE shanghai_query_operations_total counter"
    assert body =~ "# TYPE shanghai_wal_current_lsn gauge"
    assert body =~ "# TYPE shanghai_wal_active_segments gauge"
    assert body =~ "# TYPE shanghai_query_cache_hit_ratio gauge"
    assert body =~ "# TYPE shanghai_query_cache_hits_total counter"
    assert body =~ "shanghai_query_cache_size "
    assert body =~ ~s(shanghai_cluster_nodes{status="up"})
  end
end
