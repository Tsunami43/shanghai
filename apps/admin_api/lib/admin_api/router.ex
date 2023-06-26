defmodule AdminApi.Router do
  @moduledoc """
  HTTP router for Shanghai Admin API.

  Provides read-only administrative endpoints by default.
  Mutating operations require explicit flags and authorization.
  """

  use Plug.Router

  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  plug(AdminApi.Plugs.CorrelationId)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  # Readiness probe: is the node actually able to serve? Distinct from /health
  # (liveness), it checks that the essential processes are running.
  get "/ready" do
    checks = %{
      "cluster_membership" => process_alive?(Cluster.Membership),
      "replication_monitor" => process_alive?(Replication.Monitor),
      "query_store" => process_alive?(Query.Store),
      "storage_segments" => process_alive?(Storage.WAL.SegmentManager)
    }

    if Enum.all?(checks, fn {_name, up?} -> up? end) do
      send_json(conn, 200, %{status: "ready", checks: checks})
    else
      send_json(conn, 503, %{status: "not_ready", checks: checks})
    end
  end

  # Prometheus scrape endpoint (text exposition format).
  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, AdminApi.Prometheus.render())
  end

  get "/api/v1/status" do
    cluster = Cluster.cluster_state()
    nodes = Cluster.State.all_nodes(cluster)

    up_count = Cluster.State.status_count(cluster, :up)
    down_count = Cluster.State.status_count(cluster, :down)
    suspect_count = Cluster.State.status_count(cluster, :suspect)

    cluster_state =
      cond do
        down_count > 0 or suspect_count > length(nodes) / 2 -> "unavailable"
        suspect_count > 0 or up_count < length(nodes) -> "degraded"
        true -> "healthy"
      end

    status = %{
      cluster_state: cluster_state,
      node_count: Cluster.State.node_count(cluster),
      nodes_up: up_count,
      nodes_down: down_count,
      nodes_suspect: suspect_count,
      timestamp: System.system_time(:second)
    }

    send_json(conn, 200, status)
  end

  get "/api/v1/nodes" do
    nodes =
      Cluster.nodes()
      |> Enum.map(&serialize_node/1)

    send_json(conn, 200, %{nodes: nodes})
  end

  post "/api/v1/nodes" do
    Observability.Logger.info("Node operation requested", body: conn.body_params)

    with {:ok, params} <- validate_node_params(conn.body_params),
         {:ok, result} <- execute_node_action(params) do
      Observability.Logger.info("Node operation completed",
        action: params.action,
        node_id: params.id,
        result: result
      )
      send_json(conn, 200, %{status: "ok", result: result})
    else
      {:error, :invalid_params} ->
        Observability.Logger.warning("Node operation failed: invalid params", body: conn.body_params)
        send_json(conn, 400, %{error: "Invalid parameters. Required: id, action (join/leave), host, port"})

      {:error, :invalid_action} ->
        Observability.Logger.warning("Node operation failed: invalid action", body: conn.body_params)
        send_json(conn, 400, %{error: "Invalid action. Must be 'join' or 'leave'"})

      {:error, reason} ->
        Observability.Logger.error("Node operation failed", reason: reason, body: conn.body_params)
        send_json(conn, 500, %{error: "Operation failed: #{inspect(reason)}"})
    end
  end

  get "/api/v1/metrics" do
    metrics = %{
      wal: Observability.MetricsReporter.get_wal_stats(),
      replication: Observability.MetricsReporter.get_replication_stats(),
      heartbeat: Observability.MetricsReporter.get_heartbeat_stats(),
      query: Observability.MetricsReporter.get_query_stats(),
      store: query_store_info(),
      last_membership_change: Observability.MetricsReporter.get_last_membership_change()
    }

    send_json(conn, 200, metrics)
  end

  # Read a single key from the materialized store. Read-only and safe to expose
  # for operational inspection and debugging.
  get "/api/v1/kv/:key" do
    case Query.read(key) do
      {:ok, value} ->
        send_json(conn, 200, %{key: key, value: json_safe(value)})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found", key: key})
    end
  end

  get "/api/v1/replicas" do
    groups = Replication.all_groups()
    replicas = Enum.map(groups, &serialize_replication_group/1)

    send_json(conn, 200, %{replicas: replicas})
  end

  post "/api/v1/shutdown" do
    params = conn.body_params
    force = Map.get(params, "force", false)
    timeout = Map.get(params, "timeout_seconds", 30)

    Observability.Logger.warning("Shutdown requested", force: force, timeout: timeout)

    if force do
      # Immediate shutdown - spawn task to allow response to be sent
      Task.start(fn ->
        Process.sleep(100)
        Observability.Logger.warning("Forced shutdown initiated")
        System.stop(0)
      end)

      send_json(conn, 200, %{
        status: "shutdown_initiated",
        message: "Forced shutdown in progress"
      })
    else
      # Graceful shutdown - give time for connections to drain
      Task.start(fn ->
        Process.sleep(100)
        Observability.Logger.info("Graceful shutdown started", timeout: timeout)
        # In production, this would:
        # 1. Stop accepting new connections
        # 2. Drain existing connections
        # 3. Flush WAL and close files
        # 4. Notify cluster of departure
        # For now, just stop after timeout
        Process.sleep(timeout * 1000)
        Observability.Logger.info("Graceful shutdown completed")
        System.stop(0)
      end)

      send_json(conn, 202, %{
        status: "shutdown_in_progress",
        message: "Graceful shutdown initiated, timeout: #{timeout}s"
      })
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp validate_node_params(%{"id" => id, "action" => action} = params)
       when is_binary(id) and action in ["join", "leave"] do
    if action == "join" do
      with %{"host" => host, "port" => port} <- params,
           true <- is_binary(host),
           true <- is_integer(port) do
        {:ok, %{id: id, action: action, host: host, port: port}}
      else
        _ -> {:error, :invalid_params}
      end
    else
      {:ok, %{id: id, action: action}}
    end
  end

  defp validate_node_params(_), do: {:error, :invalid_params}

  defp execute_node_action(%{action: "join", id: id, host: host, port: port}) do
    node_id = NodeId.new(id)
    node = Node.new(node_id, host, port)

    case Cluster.join(node) do
      :ok -> {:ok, "Node #{id} joined successfully"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_node_action(%{action: "leave", id: id}) do
    node_id = NodeId.new(id)

    case Cluster.leave(node_id) do
      :ok -> {:ok, "Node #{id} left successfully"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp serialize_node(%Node{} = node) do
    heartbeat_age_ms =
      if node.last_seen_at do
        DateTime.diff(DateTime.utc_now(), node.last_seen_at, :millisecond)
      else
        nil
      end

    last_seen_unix =
      if node.last_seen_at do
        DateTime.to_unix(node.last_seen_at)
      else
        nil
      end

    %{
      id: node.id.value,
      status: Atom.to_string(node.status),
      address: "#{node.host}:#{node.port}",
      heartbeat_age_ms: heartbeat_age_ms,
      last_seen: last_seen_unix,
      metadata: node.metadata
    }
  end

  defp serialize_replication_group(group) do
    followers =
      group.replicas
      |> Map.values()
      |> Enum.map(fn replica ->
        %{
          node_id: replica.node_id.value,
          offset: replica.offset.value,
          lag: replica.lag,
          status: Atom.to_string(replica.status)
        }
      end)

    %{
      group_id: group.group_id,
      leader_offset: group.leader_offset.value,
      followers: followers,
      current_offset: group.leader_offset.value
    }
  end

  defp process_alive?(name), do: is_pid(Process.whereis(name))

  # Store/cache runtime summary, or an empty map if the query layer is down.
  defp query_store_info do
    case Query.info() do
      {:ok, info} -> info
      _ -> %{}
    end
  end

  # JSON carries only a subset of Erlang terms; fall back to an inspected string
  # for values that are not natively encodable (tuples, PIDs, and the like).
  defp json_safe(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> value
      {:error, _reason} -> inspect(value)
    end
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
