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
end
