defmodule Admin.Health do
  @moduledoc """
  Aggregate health check across Shanghai subsystems.

  Each subsystem contributes a boolean liveness signal (is its key process
  running?). The overall status is `:healthy` when every check passes and
  `:degraded` otherwise.
  """

  alias Cluster.Membership
  alias Query.Store
  alias Replication.Monitor
  alias Storage.WAL.SegmentManager

  @type checks :: %{atom() => boolean()}
  @type report :: %{status: :healthy | :degraded, checks: checks()}

  @doc "Runs the live subsystem checks and returns an aggregate report."
  @spec check() :: report()
  def check do
    checks = %{
      storage: alive?(SegmentManager),
      cluster: alive?(Membership),
      replication: alive?(Monitor),
      query: alive?(Store)
    }

    %{status: status_of(checks), checks: checks}
  end

  @doc "Reduces a checks map to an overall status."
  @spec status_of(checks()) :: :healthy | :degraded
  def status_of(checks) do
    if Enum.all?(Map.values(checks)), do: :healthy, else: :degraded
  end

  defp alive?(name), do: is_pid(Process.whereis(name))
end
