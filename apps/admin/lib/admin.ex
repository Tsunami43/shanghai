defmodule Admin do
  @moduledoc """
  Cross-cutting administration entry point for Shanghai.

  It composes the other bounded contexts to expose operational concerns. Today
  it provides an aggregate health check; the HTTP and CLI surfaces live in the
  `admin_api` and `shanghaictl` apps.
  """

  @doc """
  Returns the aggregate health report across subsystems.

  See `Admin.Health.check/0`.
  """
  @spec health() :: Admin.Health.report()
  defdelegate health(), to: Admin.Health, as: :check

  @doc "Returns `true` when every subsystem is healthy. See `Admin.Health.healthy?/0`."
  @spec healthy?() :: boolean()
  defdelegate healthy?(), to: Admin.Health

  @doc "Returns `true` when at least one subsystem is unhealthy."
  @spec degraded?() :: boolean()
  defdelegate degraded?(), to: Admin.Health

  @doc "Returns the subsystems whose health check is failing. See `Admin.Health.unhealthy_subsystems/0`."
  @spec unhealthy_subsystems() :: [atom()]
  defdelegate unhealthy_subsystems(), to: Admin.Health

  @doc "Returns the subsystems whose health check is passing. See `Admin.Health.healthy_subsystems/0`."
  @spec healthy_subsystems() :: [atom()]
  defdelegate healthy_subsystems(), to: Admin.Health

  @doc """
  Returns a one-call health summary: status, healthy/total subsystem counts, the
  health ratio, and the sorted unhealthy subsystems. See `Admin.Health.summary/0`.
  """
  @spec summary() :: %{
          status: :healthy | :degraded,
          healthy: non_neg_integer(),
          total: non_neg_integer(),
          ratio: float(),
          unhealthy: [atom()]
        }
  defdelegate summary(), to: Admin.Health

  @doc """
  Returns the fraction of healthy subsystems (0.0..1.0), `1.0` when there are no
  subsystems. A convenience over `summary/0`'s `:ratio`.
  """
  @spec health_ratio() :: float()
  def health_ratio, do: summary().ratio
end
