defmodule AdminApi.Router do
  @moduledoc """
  HTTP router for Shanghai Admin API.

  Provides read-only administrative endpoints by default.
  Mutating operations require explicit flags and authorization.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  get "/api/v1/status" do
    status = %{
      cluster_state: "healthy",
      node_count: 3,
      timestamp: System.system_time(:second)
    }

    send_json(conn, 200, status)
  end

  get "/api/v1/nodes" do
    nodes = [
      %{
        id: "node-1",
        status: "up",
        address: "127.0.0.1:8001",
        heartbeat_age_ms: 100,
        last_seen: System.system_time(:second) - 1
      },
      %{
        id: "node-2",
        status: "up",
        address: "127.0.0.1:8002",
        heartbeat_age_ms: 150,
        last_seen: System.system_time(:second) - 2
      },
      %{
        id: "node-3",
        status: "suspect",
        address: "127.0.0.1:8003",
        heartbeat_age_ms: 3000,
        last_seen: System.system_time(:second) - 30
      }
    ]

    send_json(conn, 200, %{nodes: nodes})
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

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
