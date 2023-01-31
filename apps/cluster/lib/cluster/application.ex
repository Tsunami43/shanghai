defmodule Cluster.Application do
  @moduledoc """
  OTP Application for the Shanghai Cluster.

  Starts and supervises the cluster management processes:
  - Membership: Tracks cluster topology and membership changes
  - Heartbeat: Monitors node liveness via heartbeats
  - Gossip: Propagates events and state across the cluster
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Shanghai Cluster application")

    children = [
      # Membership must start first as Heartbeat and Gossip depend on it
      {Cluster.Membership, []},
      # Heartbeat monitors node liveness
      {Cluster.Heartbeat, []},
      # Gossip propagates events across the cluster
      {Cluster.Gossip, []}
    ]

    # Use :one_for_one strategy: if a child process crashes, only that process is restarted
    # This ensures independence between the cluster components
    opts = [strategy: :one_for_one, name: Cluster.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
