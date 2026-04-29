defmodule Storage.WALTestInfra do
  @moduledoc """
  Test helper for the shared, singleton WAL infrastructure.

  `Storage.WAL.SegmentRegistry` and `Storage.WAL.SegmentManager` are registered
  under fixed names, so at most one of each can exist in the VM. When several
  test modules each start them in `setup_all`, running in the same VM (as the
  umbrella test run does) races: the second `start_link` returns
  `{:error, {:already_started, _}}` and a naive `{:ok, _} = ...` match crashes
  the whole module's `setup_all`.

  Call `ensure_started/0` from `setup_all` instead; it starts each process if
  needed and tolerates one that is already running.
  """

  alias Storage.WAL.SegmentManager

  @registry Storage.WAL.SegmentRegistry

  @doc """
  Ensures the shared segment Registry and SegmentManager are running.

  Idempotent and safe to call from every module's `setup_all`.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    ensure(fn -> Registry.start_link(keys: :unique, name: @registry) end)
    ensure(fn -> SegmentManager.start_link(:ok) end)
    :ok
  end

  defp ensure(start_fun) do
    case start_fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
