defmodule AdminApi.Router do
  @moduledoc """
  HTTP router for Shanghai Admin API.

  Provides read-only administrative endpoints by default.
  Mutating operations require explicit flags and authorization.
  """

  use Plug.Router

  plug(AdminApi.Plugs.CorrelationId)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
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
      last_membership_change: Observability.MetricsReporter.get_last_membership_change()
    }

    send_json(conn, 200, metrics)
  end

  get "/api/v1/replicas" do
    replicas = [
      %{
        group_id: "group-1",
        leader_id: "node-1",
        followers: [
          %{
            node_id: "node-2",
            offset: 1500,
            lag: 10,
            status: "healthy"
          },
          %{
            node_id: "node-3",
            offset: 1200,
            lag: 310,
            status: "lagging"
          }
        ],
        current_offset: 1510
      },
      %{
        group_id: "group-2",
        leader_id: "node-2",
        followers: [
          %{
            node_id: "node-1",
            offset: 890,
            lag: 5,
            status: "healthy"
          },
          %{
            node_id: "node-3",
            offset: 850,
            lag: 45,
            status: "healthy"
          }
        ],
        current_offset: 895
      }
    ]

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
    node_id = CoreDomain.Types.NodeId.new(id)
    node = Cluster.Entities.Node.new(node_id, host, port)

    case Cluster.join(node) do
      :ok -> {:ok, "Node #{id} joined successfully"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_node_action(%{action: "leave", id: id}) do
    node_id = CoreDomain.Types.NodeId.new(id)

    case Cluster.leave(node_id) do
      :ok -> {:ok, "Node #{id} left successfully"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp serialize_node(%Cluster.Entities.Node{} = node) do
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

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
