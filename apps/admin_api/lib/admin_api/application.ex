defmodule AdminApi.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:admin_api, :port, 9090)

    children = [
      {Plug.Cowboy, scheme: :http, plug: AdminApi.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: AdminApi.Supervisor]

    Logger.info("Starting Admin API on port #{port}")

    Supervisor.start_link(children, opts)
  end
end
