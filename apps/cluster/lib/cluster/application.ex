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
      # Membership must start first as the others depend on it
      {Cluster.Membership, []},
      # Leader election derives the leader from the membership view
      {Cluster.LeaderElection, []},
      # Discovery connects to configured seed nodes over Erlang distribution
      {Cluster.Discovery, []},
      # Heartbeat monitors node liveness
      {Cluster.Heartbeat, heartbeat_opts()},
      # Gossip propagates events across the cluster
      {Cluster.Gossip, gossip_opts()}
    ]

    # Use :one_for_one strategy: if a child process crashes, only that process is restarted
    # This ensures independence between the cluster components
    opts = [strategy: :one_for_one, name: Cluster.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Heartbeat options resolved from `:cluster` application config, with defaults.

  Config keys: `:heartbeat_interval_ms`, `:down_timeout_ms`, `:suspect_timeout_ms`.
  """
  @spec heartbeat_opts() :: keyword()
  def heartbeat_opts do
    [
      interval_ms: Application.get_env(:cluster, :heartbeat_interval_ms, 5_000),
      timeout_ms: Application.get_env(:cluster, :down_timeout_ms, 15_000),
      suspect_timeout_ms: Application.get_env(:cluster, :suspect_timeout_ms, 10_000)
    ]
  end

  @doc """
  Gossip options resolved from `:cluster` application config, with defaults.

  Config keys: `:gossip_fanout`, `:gossip_interval_ms`.
  """
  @spec gossip_opts() :: keyword()
  def gossip_opts do
    [
      fanout: Application.get_env(:cluster, :gossip_fanout, 3),
      interval_ms: Application.get_env(:cluster, :gossip_interval_ms, 1_000)
    ]
  end
end
