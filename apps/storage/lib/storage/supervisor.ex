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
      # TODO: Configure Writer, Reader, and Snapshot.Manager with proper directories
      # {Storage.WAL.Writer, []},
      # {Storage.WAL.Reader, []},
      # {Storage.Snapshot.Manager, []},
      {Storage.Compaction.Compactor, []}
      # TODO: Add Storage.WAL.SegmentManager (DynamicSupervisor)
      # TODO: Add Storage.Index.SegmentIndex
      # TODO: Add Storage.Compaction.Scheduler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
