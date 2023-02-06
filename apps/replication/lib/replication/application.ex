defmodule Replication.Application do
  @moduledoc """
  OTP Application for Shanghai Replication.

  Starts and supervises the replication management processes:
  - Registry: Process registry for leader/follower processes
  - Monitor: Monitors replication health and lag
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Shanghai Replication application")

    children = [
      # Registry for leader and follower processes
      {Registry, keys: :unique, name: Replication.Registry}
      # Monitor will be added later
      # {Replication.Monitor, []}
    ]

    opts = [strategy: :one_for_one, name: Replication.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
