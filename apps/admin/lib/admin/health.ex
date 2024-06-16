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

  @doc """
  Returns the fraction of subsystem checks that pass (0.0..1.0). Returns `1.0`
  for an empty checks map.
  """
  @spec health_ratio(checks()) :: float()
  def health_ratio(checks) when map_size(checks) == 0, do: 1.0

  def health_ratio(checks) do
    up = checks |> Map.values() |> Enum.count(& &1)
    up / map_size(checks)
  end

  @doc "Returns `true` when every subsystem check passes."
  @spec healthy?() :: boolean()
  def healthy?, do: check().status == :healthy

  @doc "Returns `true` when at least one subsystem check fails."
  @spec degraded?() :: boolean()
  def degraded?, do: check().status == :degraded

  @doc """
  Returns the names of the subsystems whose check is currently failing (empty
  when everything is healthy). Useful for alerting and log context.
  """
  @spec unhealthy_subsystems() :: [atom()]
  def unhealthy_subsystems do
    check().checks
    |> Enum.filter(fn {_name, up?} -> not up? end)
    |> Enum.map(fn {name, _up?} -> name end)
    |> Enum.sort()
  end

  @doc """
  Returns the names of the subsystems whose check is currently passing, sorted.
  The complement of `unhealthy_subsystems/0`.
  """
  @spec healthy_subsystems() :: [atom()]
  def healthy_subsystems do
    check().checks
    |> Enum.filter(fn {_name, up?} -> up? end)
    |> Enum.map(fn {name, _up?} -> name end)
    |> Enum.sort()
  end

  defp alive?(name), do: is_pid(Process.whereis(name))
end
