defmodule Storage.Supervisor do
  @moduledoc """
  Main supervisor for the Storage application.

  Supervises all storage-related processes including:
  - WAL (Write-Ahead Log) writer and reader
  - Compaction processes
  - Snapshot manager
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Storage.WAL.Writer, []},
      {Storage.WAL.Reader, []},
      {Storage.Compaction.Compactor, []},
      {Storage.Snapshot.Manager, []}
      # TODO: Add Storage.WAL.SegmentManager (DynamicSupervisor)
      # TODO: Add Storage.Compaction.Scheduler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
