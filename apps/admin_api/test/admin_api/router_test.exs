defmodule AdminApi.RouterTest do
  @moduledoc """
  Exercises the read-only Admin HTTP API endpoints against the live
  cluster/replication/observability processes started with the app.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

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
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    assert json(conn) == %{"status" => "ok"}
  end

  test "GET /ready reports readiness with per-process checks" do
    conn = get("/ready")
    assert conn.status == 200

    body = json(conn)
    assert body["status"] == "ready"
    assert body["checks"]["cluster_membership"] == true
    assert body["checks"]["replication_monitor"] == true
    assert body["checks"]["query_store"] == true
    assert body["checks"]["storage_segments"] == true
  end

  test "GET /api/v1 lists the available endpoints" do
    conn = get("/api/v1")
    assert conn.status == 200

    body = json(conn)
    assert body["service"] == "shanghai"
    assert is_list(body["endpoints"])
    assert "/api/v1/status" in body["endpoints"]
    assert "/api/v1/info" in body["endpoints"]
    assert "/api/v1/keys" in body["endpoints"]
    assert "POST /api/v1/compaction" in body["endpoints"]
  end

  test "GET /api/v1/info reports version and runtime details" do
    conn = get("/api/v1/info")
    assert conn.status == 200

    body = json(conn)
    assert is_binary(body["node_id"])
    assert is_binary(body["version"])
    assert body["elixir_version"] == System.version()
    assert is_binary(body["otp_release"])
  end

  test "GET /api/v1/status reports cluster health fields" do
    conn = get("/api/v1/status")
    assert conn.status == 200

    body = json(conn)
    assert body["cluster_state"] in ["healthy", "degraded", "unavailable"]
    assert is_binary(body["local_node_id"])
    assert is_boolean(body["quorum_available"])
    assert is_integer(body["quorum_size"])
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

  test "GET /api/v1/nodes/:id returns a single node or 404" do
    id = "router-node-#{:rand.uniform(999_999)}"
    node_id = NodeId.new(id)
    :ok = Cluster.join(Node.new(node_id, "localhost", 4400))

    conn = get("/api/v1/nodes/#{id}")
    assert conn.status == 200
    assert json(conn)["id"] == id

    missing = get("/api/v1/nodes/router-absent")
    assert missing.status == 404
    assert json(missing)["error"] == "not_found"

    :ok = Cluster.leave(node_id)
  end

  test "POST /api/v1/compaction returns 503 when compaction is not running" do
    conn =
      :post
      |> conn("/api/v1/compaction")
      |> AdminApi.Router.call(@opts)

    assert conn.status == 503
    assert json(conn)["error"] == "compaction_not_running"
  end

  test "POST /api/v1/snapshots returns 503 when snapshots are not running" do
    conn =
      :post
      |> conn("/api/v1/snapshots")
      |> AdminApi.Router.call(@opts)

    assert conn.status == 503
    assert json(conn)["error"] == "snapshots_not_running"
  end

  test "GET /api/v1/snapshots returns a snapshot list and count" do
    conn = get("/api/v1/snapshots")
    assert conn.status == 200

    body = json(conn)
    assert is_list(body["snapshots"])
    assert body["count"] == length(body["snapshots"])
  end

  test "GET /api/v1/replicas returns a replicas list and summary" do
    conn = get("/api/v1/replicas")
    assert conn.status == 200

    body = json(conn)
    assert is_list(body["replicas"])
    assert is_integer(body["summary"]["groups"])
    assert is_integer(body["summary"]["replicas"])
    assert is_integer(body["summary"]["lagging"])
    assert is_integer(body["summary"]["stale"])
  end

  test "GET /api/v1/kv counts stored keys, with an optional prefix filter" do
    {:ok, :written} = Query.write("count-api:a", 1)
    {:ok, :written} = Query.write("count-api:b", 2)

    total = get("/api/v1/kv")
    assert total.status == 200
    assert is_integer(json(total)["count"])

    scoped = get("/api/v1/kv?prefix=count-api:")
    assert scoped.status == 200
    body = json(scoped)
    assert body["prefix"] == "count-api:"
    assert body["count"] == 2
  end

  test "GET /api/v1/keys lists keys under a prefix with a limit" do
    {:ok, :written} = Query.write("keys-api:1", 1)
    {:ok, :written} = Query.write("keys-api:2", 2)
    {:ok, :written} = Query.write("keys-api:3", 3)

    conn = get("/api/v1/keys?prefix=keys-api:&limit=2")
    assert conn.status == 200

    body = json(conn)
    assert body["keys"] == ["keys-api:1", "keys-api:2"]
    assert body["count"] == 2
    assert body["limit"] == 2
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
    assert Map.has_key?(body, "store")
    assert is_map(body["store"]["store"])
    assert is_map(body["store"]["cache"])
    assert Map.has_key?(body, "compaction")
    assert is_integer(body["compaction"]["count"])
    assert Map.has_key?(body, "storage")
    assert is_integer(body["storage"]["bytes"])
    assert is_boolean(body["storage"]["wal_running"])
    assert is_map(body["storage"]["compaction"])
    assert is_boolean(body["storage"]["compaction"]["running"])
  end

  test "sets an X-Correlation-ID response header" do
    conn = get("/health")
    assert [_correlation_id] = get_resp_header(conn, "x-correlation-id")
  end

  test "echoes a client-supplied X-Correlation-ID" do
    conn =
      :get
      |> conn("/health")
      |> put_req_header("x-correlation-id", "trace-123")
      |> AdminApi.Router.call(@opts)

    assert get_resp_header(conn, "x-correlation-id") == ["trace-123"]
  end

  test "unknown routes return a JSON 404" do
    conn = get("/api/v1/nope")
    assert conn.status == 404
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    body = json(conn)
    assert body["error"] == "not_found"
    assert body["path"] == "/api/v1/nope"
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
    assert body =~ "# TYPE shanghai_query_operation_duration_ms summary"
    assert body =~ "# TYPE shanghai_wal_current_lsn gauge"
    assert body =~ "# TYPE shanghai_wal_active_segments gauge"
    assert body =~ "# TYPE shanghai_wal_entries gauge"
    assert body =~ "# TYPE shanghai_wal_bytes gauge"
    assert body =~ "# TYPE shanghai_storage_snapshots gauge"
    assert body =~ "# TYPE shanghai_compaction_runs_total counter"
    assert body =~ "# TYPE shanghai_compaction_bytes_reclaimed_total counter"
    assert body =~ "# TYPE shanghai_query_store_keys gauge"
    assert body =~ "# TYPE shanghai_query_store_memory_bytes gauge"
    assert body =~ "# TYPE shanghai_query_cache_hit_ratio gauge"
    assert body =~ "# TYPE shanghai_query_cache_hits_total counter"
    assert body =~ "shanghai_query_cache_size "
    assert body =~ ~s(shanghai_cluster_nodes{status="up"})
  end
end
