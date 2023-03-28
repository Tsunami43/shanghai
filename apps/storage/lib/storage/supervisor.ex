defmodule Storage.Supervisor do
  @moduledoc """
  Main supervisor for the Storage application.

  Supervises all storage-related processes including:
  - WAL segment management (SegmentManager, Writer, Reader)
  - Indexing (SegmentIndex)
  - Snapshot management
  - Compaction (Compactor, Scheduler)

  ## Configuration

  The supervisor expects configuration to be provided via Application environment:

      config :storage,
        data_root: "/var/lib/shanghai/data"

  All storage components will be initialized based on this configuration.
  If no configuration is provided, storage components will not be started.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Get configuration from Application environment
    data_root = Application.get_env(:storage, :data_root)

    children =
      if data_root do
        # Full storage stack with configuration
        build_children_with_config(data_root)
      else
        # No configuration - start minimal components
        build_minimal_children()
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Builds full storage stack when configuration is available
  defp build_children_with_config(data_root) do
    wal_dir = Path.join(data_root, "wal")
    segments_dir = Path.join(wal_dir, "segments")
    index_dir = Path.join(data_root, "index")
    snapshots_dir = Path.join(data_root, "snapshots")

    node_id = Application.get_env(:storage, :node_id, "default_node")

    segment_size_threshold =
      Application.get_env(:storage, :segment_size_threshold, 64 * 1024 * 1024)

    segment_time_threshold = Application.get_env(:storage, :segment_time_threshold, 3600)

    [
      # Core WAL infrastructure
      {Storage.WAL.SegmentManager, []},
      {Storage.Index.SegmentIndex, [data_dir: index_dir]},

      # WAL Writer and Reader
      {Storage.WAL.Writer,
       [
         data_dir: segments_dir,
         node_id: node_id,
         segment_size_threshold: segment_size_threshold,
         segment_time_threshold: segment_time_threshold
       ]},
      {Storage.WAL.Reader, []},

      # Snapshot management
      {Storage.Snapshot.Manager,
       [
         snapshots_dir: snapshots_dir,
         retention_count: Application.get_env(:storage, :snapshot_retention, 5)
       ]},

      # Compaction
      {Storage.Compaction.Compactor,
       [
         data_dir: segments_dir,
         strategy:
           Application.get_env(
             :storage,
             :compaction_strategy,
             Storage.Compaction.Strategy.SizeTiered
           )
       ]},
      {Storage.Compaction.Scheduler,
       [
         interval: Application.get_env(:storage, :compaction_interval, 3_600_000),
         enabled: Application.get_env(:storage, :compaction_enabled, true)
       ]}
    ]
  end

  # Builds minimal children when no configuration is provided
  defp build_minimal_children do
    [
      # Only start components that don't require configuration
      {Storage.Compaction.Compactor, []}
    ]
  end
end
