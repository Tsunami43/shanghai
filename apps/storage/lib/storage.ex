defmodule Storage do
  @moduledoc """
  Public facade for the storage subsystem (the Write-Ahead Log).

  Thin delegation to the WAL processes plus a small runtime summary. The full
  stack (`Writer`/`Reader`) is available when `:storage` is configured with a
  `data_root`; the segment `Registry`/`SegmentManager` are always running.
  """

  alias Storage.Compaction.Scheduler, as: CompactionScheduler
  alias Storage.Snapshot.Manager, as: SnapshotManager
  alias Storage.WAL.{Reader, Segment, SegmentManager, Writer}

  @doc "Appends data to the WAL. Requires the WAL `Writer` to be running."
  @spec append(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate append(data), to: Writer

  @doc "Reads a log entry by LSN. Requires the WAL `Reader` to be running."
  @spec read(non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defdelegate read(lsn), to: Reader

  @doc """
  Reads log entries from `start_lsn` to `end_lsn` (inclusive), in LSN order.
  Requires the WAL `Reader` to be running.
  """
  @spec read_range(non_neg_integer(), non_neg_integer()) ::
          {:ok, [term()]} | {:error, term()}
  defdelegate read_range(start_lsn, end_lsn), to: Reader

  @doc """
  Returns a runtime summary of the storage subsystem.

  `current_lsn` is the next LSN the WAL will assign (the log length); it is `0`
  when the `Writer` is not running.

  ## Examples

      iex> info = Storage.info()
      iex> is_boolean(info.wal_running) and is_integer(info.active_segments)
      true
  """
  @spec info() :: %{
          wal_running: boolean(),
          active_segments: non_neg_integer(),
          current_lsn: non_neg_integer(),
          snapshots: non_neg_integer()
        }
  def info do
    %{
      wal_running: is_pid(Process.whereis(Writer)),
      active_segments: SegmentManager.count(),
      current_lsn: current_lsn(),
      snapshots: length(list_snapshots())
    }
  end

  @doc """
  Aggregates on-disk WAL statistics across all active segments: the segment
  count, the total number of entries, and the total file size in bytes.

  ## Examples

      iex> stats = Storage.wal_stats()
      iex> is_integer(stats.segments) and is_integer(stats.bytes)
      true
  """
  @spec wal_stats() :: %{
          segments: non_neg_integer(),
          entries: non_neg_integer(),
          bytes: non_neg_integer()
        }
  def wal_stats do
    segments = SegmentManager.list_segments()

    Enum.reduce(segments, %{segments: length(segments), entries: 0, bytes: 0}, fn {_id, pid},
                                                                                  acc ->
      case Segment.stats(pid) do
        {:ok, stats} ->
          %{
            acc
            | entries: acc.entries + Map.get(stats, :entry_count, 0),
              bytes: acc.bytes + Map.get(stats, :file_size, 0)
          }

        _error ->
          acc
      end
    end)
  end

  @doc """
  Lists persisted snapshots (most recent first when the manager sorts them), or
  `[]` when the snapshot manager is not running (e.g. no `data_root` configured).
  """
  @spec list_snapshots() :: [map()]
  def list_snapshots do
    if is_pid(Process.whereis(SnapshotManager)) do
      case SnapshotManager.list_snapshots() do
        {:ok, snapshots} -> snapshots
        _error -> []
      end
    else
      []
    end
  end

  @doc """
  Triggers a compaction run immediately when the scheduler is running. Returns
  `:ok`, or `{:error, :not_running}` when compaction is not configured.
  """
  @spec trigger_compaction() :: :ok | {:error, :not_running}
  def trigger_compaction do
    if is_pid(Process.whereis(CompactionScheduler)) do
      CompactionScheduler.trigger_compaction()
    else
      {:error, :not_running}
    end
  end

  @doc """
  Returns the compaction scheduler status: `%{running: true, enabled: bool,
  interval_ms: n}` when the scheduler is up, otherwise `%{running: false}`.
  """
  @spec compaction_status() :: map()
  def compaction_status do
    if is_pid(Process.whereis(CompactionScheduler)) do
      case CompactionScheduler.stats() do
        {:ok, stats} ->
          %{running: true, enabled: stats.enabled, interval_ms: stats.interval}

        _error ->
          %{running: false}
      end
    else
      %{running: false}
    end
  end

  # The next LSN the Writer will assign, or 0 when it is not running.
  defp current_lsn do
    case Process.whereis(Writer) && Writer.info() do
      {:ok, %{current_lsn: lsn}} -> lsn
      _ -> 0
    end
  end
end
