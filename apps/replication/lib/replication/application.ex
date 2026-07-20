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

    # Monitor tracks replication health/lag; the public Replication API and the
    # Admin API's /replicas and /metrics endpoints depend on it. It is enabled
    # by default and disabled under the test env (see config/test.exs), where
    # replication's own tests start a Monitor with custom settings.
    monitor_children =
      if Application.get_env(:replication, :start_monitor, true) do
        [{Replication.Monitor, monitor_opts()}]
      else
        []
      end

    children =
      [
        # Registry for leader and follower processes
        {Registry, keys: :unique, name: Replication.Registry}
      ] ++
        epoch_children() ++
        [
          # Dynamic supervisor under which per-group leader/stream/follower
          # processes are started via Replication.start_leader/2 and
          # start_follower/2.
          {DynamicSupervisor, strategy: :one_for_one, name: Replication.GroupSupervisor}
        ] ++ monitor_children ++ coordinator_children()

    opts = [strategy: :one_for_one, name: Replication.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Per-group leadership epochs and votes, started before anything that can
  # stand for election or apply a replicated entry. Disabled in the test env
  # (see config/test.exs), where tests own this singleton so they can restart
  # it to prove a vote is durable.
  defp epoch_children do
    if Application.get_env(:replication, :start_epoch, true) do
      [Replication.Epoch]
    else
      []
    end
  end

  # One GroupCoordinator per group configured via `config :replication, :groups`.
  # Each keeps its group's role on this node in step with cluster membership
  # (leader failover). Started after the Registry and GroupSupervisor they use.
  defp coordinator_children do
    for opts <- Replication.configured_groups() do
      Supervisor.child_spec({Replication.GroupCoordinator, opts},
        id: {Replication.GroupCoordinator, opts[:group_id]}
      )
    end
  end

  @doc """
  Monitor options resolved from `config :replication, Replication.Monitor, ...`.

  Recognized keys: `:lag_threshold`, `:stale_threshold_ms`, `:check_interval_ms`.
  When unset, `Replication.Monitor` applies its own defaults.
  """
  @spec monitor_opts() :: keyword()
  def monitor_opts do
    Application.get_env(:replication, Replication.Monitor, [])
  end
end
