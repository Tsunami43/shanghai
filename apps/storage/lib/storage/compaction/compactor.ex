defmodule Storage.Compaction.Compactor do
  @moduledoc """
  GenServer responsible for compacting storage segments.

  Periodically merges and compacts old segments to:
  - Reduce total segment count
  - Merge small segments into larger ones
  - Optimize read performance

  ## Compaction Process

  1. Use strategy to select segment groups to compact
  2. Read all entries from selected segments (sorted by LSN)
  3. Write entries to new merged segment
  4. Update SegmentIndex with new segment
  5. Delete old segments atomically

  ## What compaction does and does not do

  A group is merged into a single segment; every entry is carried over. No
  entry is ever dropped, so `Storage.read/1` returns the same data for every
  LSN before and after a run. The space reclaimed is therefore only the
  per-segment file headers - the real wins are fewer files, fewer segment
  processes and a shorter scan during index rebuild.

  Discarding entries already covered by a snapshot (WAL truncation) is a
  separate, unimplemented feature: it would change read semantics and needs a
  guarantee that snapshots fully cover the truncated range.

  The segment the WAL Writer is currently appending to is never compacted.

  ## Configuration

  - `:strategy` - Compaction strategy module (default: SizeTiered)
  - `:data_dir` - Directory for WAL segments
  """

  use GenServer
  require Logger

  alias Storage.Index.SegmentIndex
  alias Storage.Persistence.FileBackend
  alias Storage.WAL.{Segment, SegmentManager, Writer}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            compaction_in_progress: boolean(),
            last_compaction: DateTime.t() | nil,
            strategy: module(),
            data_dir: String.t() | nil
          }

    defstruct compaction_in_progress: false,
              last_compaction: nil,
              strategy: Storage.Compaction.Strategy.SizeTiered,
              data_dir: nil
  end

  ## Client API

  @doc """
  Starts the Compactor GenServer.

  ## Options

  - `:strategy` - Compaction strategy module (default: SizeTiered)
  - `:data_dir` - Directory for WAL segments
  - `:name` - Registered name (default: `#{inspect(__MODULE__)}`). Tests use
    this to run an isolated compactor alongside the supervised singleton.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers a compaction run.

  Returns `:ok` if compaction started, `{:error, :already_running}` if
  a compaction is already in progress.

  ## Examples

      iex> Compactor.compact()
      :ok
  """
  @spec compact(GenServer.server()) :: :ok | {:error, :already_running}
  def compact(server \\ __MODULE__) do
    GenServer.call(server, :compact, :infinity)
  end

  @doc """
  Gets compaction statistics.

  ## Examples

      iex> Compactor.stats()
      {:ok, %{in_progress: false, last_compaction: ~U[...]}}
  """
  @spec stats(GenServer.server()) :: {:ok, map()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    strategy = Keyword.get(opts, :strategy, Storage.Compaction.Strategy.SizeTiered)
    data_dir = Keyword.get(opts, :data_dir)

    state = %State{
      strategy: strategy,
      data_dir: data_dir
    }

    Logger.info("Compaction.Compactor initialized, strategy: #{inspect(strategy)}")

    {:ok, state}
  end

  @impl true
  def handle_call(:compact, _from, %State{compaction_in_progress: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    # Mark compaction as in progress
    new_state = %{state | compaction_in_progress: true}

    # Run compaction asynchronously, reporting back to this server rather than
    # to the module name, so a non-default instance also gets its result.
    server = self()
    Task.start(fn -> run_compaction(state, server) end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      in_progress: state.compaction_in_progress,
      last_compaction: state.last_compaction,
      strategy: state.strategy
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info(:compaction_complete, state) do
    new_state = %{state | compaction_in_progress: false, last_compaction: DateTime.utc_now()}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:compaction_failed, reason}, state) do
    Logger.error("Compaction failed: #{inspect(reason)}")
    new_state = %{state | compaction_in_progress: false}
    {:noreply, new_state}
  end

  ## Private Functions

  @spec run_compaction(State.t(), pid()) :: :ok | {:error, term()}
  defp run_compaction(state, server) do
    Logger.info("Starting compaction run")

    try do
      :ok = perform_compaction(state)
      send(server, :compaction_complete)
      :ok
    rescue
      e ->
        error = {:compaction_crash, Exception.message(e)}
        send(server, {:compaction_failed, error})
        {:error, error}
    end
  end

  @spec perform_compaction(State.t()) :: :ok | {:error, term()}
  defp perform_compaction(%State{data_dir: nil}) do
    # Without a data directory the segment files cannot be located, so there is
    # nothing this run can safely rewrite.
    Logger.info("Compaction skipped: no data_dir configured")
    :ok
  end

  defp perform_compaction(state) do
    # Get all segments, minus the one the Writer is still appending to.
    active_id = active_segment_id()

    segments =
      Enum.reject(SegmentManager.list_segments(), fn {segment_id, _pid} ->
        segment_id == active_id
      end)

    # Get segment info
    segment_infos =
      Enum.map(segments, fn {segment_id, segment_pid} ->
        case Segment.stats(segment_pid) do
          {:ok, stats} ->
            %{
              id: segment_id,
              size: stats.file_size,
              start_lsn: stats.start_lsn,
              end_lsn: stats.current_lsn - 1,
              entry_count: stats.entry_count
            }

          {:error, _} ->
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    # Use strategy to select segments to compact
    groups_to_compact = state.strategy.select_segments(segment_infos)

    Logger.info("Selected #{length(groups_to_compact)} segment groups for compaction")

    # Compact each group
    Enum.each(groups_to_compact, fn group ->
      compact_segment_group(group, state)
    end)

    :ok
  end

  @spec compact_segment_group([non_neg_integer()], State.t()) :: :ok | {:error, term()}
  defp compact_segment_group(segment_ids, state) do
    Logger.info("Compacting segment group: #{inspect(segment_ids)}")

    # The lowest id in the group becomes the merged segment, so no new segment
    # id is allocated and the Writer's id sequence is left alone.
    ids = Enum.sort(segment_ids)
    target_id = hd(ids)
    segments_dir = segments_dir(state)
    target_path = segment_file_path(segments_dir, target_id)
    temp_path = target_path <> ".compacting"

    bytes_before = total_segment_bytes(ids)
    {:ok, entries} = read_entries_from_segments(ids)

    case Enum.sort_by(entries, & &1.lsn.value) do
      [] ->
        Logger.info("No entries found in segment group, skipping")
        :ok

      sorted_entries ->
        merge_group(ids, target_id, target_path, temp_path, sorted_entries, bytes_before)
    end
  end

  # Writes the merged segment to a temporary file, then swaps it in. The
  # temporary file means a crash before the swap leaves the source segments
  # untouched, so the group is simply re-selected on the next run.
  @spec merge_group(
          [non_neg_integer()],
          non_neg_integer(),
          String.t(),
          String.t(),
          [term()],
          non_neg_integer()
        ) :: :ok | {:error, term()}
  defp merge_group(ids, target_id, target_path, temp_path, sorted_entries, bytes_before) do
    start_lsn = hd(sorted_entries).lsn.value
    end_lsn = List.last(sorted_entries).lsn.value
    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "Merging #{length(sorted_entries)} entries from LSN #{start_lsn} to #{end_lsn} " <>
        "into segment #{target_id}"
    )

    case write_merged_segment(temp_path, target_id, start_lsn, sorted_entries) do
      {:ok, placements} ->
        :ok =
          swap_in_merged_segment(ids, target_id, target_path, temp_path, start_lsn, placements)

        bytes_after = file_size(target_path)

        Observability.Metrics.compaction_completed(
          System.monotonic_time(:millisecond) - started_at,
          bytes_before,
          bytes_after,
          ids
        )

        Logger.info(
          "Compacted #{length(ids)} segments into segment #{target_id} " <>
            "(#{bytes_before} -> #{bytes_after} bytes)"
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Failed to write merged segment #{target_id}: #{inspect(reason)}")
        File.rm(temp_path)
        error
    end
  end

  # Writes every entry into a detached segment process pointed at the temporary
  # file, returning the offset each LSN landed at so the index can be repointed.
  @spec write_merged_segment(String.t(), non_neg_integer(), non_neg_integer(), [term()]) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, term()}
  defp write_merged_segment(temp_path, target_id, start_lsn, sorted_entries) do
    File.rm(temp_path)

    opts = [segment_id: target_id, start_lsn: start_lsn, path: temp_path, create: true]

    case Segment.start_link(opts) do
      {:ok, pid} ->
        try do
          placements =
            Enum.map(sorted_entries, fn entry ->
              {:ok, offset} = Segment.append_entry_no_sync(pid, entry)
              {entry.lsn.value, offset}
            end)

          :ok = Segment.sync(pid)
          {:ok, placements}
        after
          Segment.close(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Replaces the source segments with the merged file and repoints the index.
  # Reads that race this window can fail; they succeed again once the merged
  # segment is registered.
  @spec swap_in_merged_segment(
          [non_neg_integer()],
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          [{non_neg_integer(), non_neg_integer()}]
        ) :: :ok
  defp swap_in_merged_segment(ids, target_id, target_path, temp_path, start_lsn, placements) do
    segments_dir = Path.dirname(target_path)

    # Release the file handles before touching the files themselves.
    Enum.each(ids, &SegmentManager.stop_segment/1)

    :ok = File.rename(temp_path, target_path)

    ids
    |> Enum.reject(&(&1 == target_id))
    |> Enum.each(fn id -> FileBackend.delete_file(segment_file_path(segments_dir, id)) end)

    FileBackend.sync_directory(segments_dir)

    {:ok, _pid} = SegmentManager.start_segment(target_id, start_lsn, target_path, create: false)

    repoint_index(ids, target_id, placements)
  end

  # Drops the index entries of every source segment, then records where each
  # LSN now lives. Skipped when the index is not running (minimal storage tree).
  @spec repoint_index([non_neg_integer()], non_neg_integer(), [
          {non_neg_integer(), non_neg_integer()}
        ]) :: :ok
  defp repoint_index(ids, target_id, placements) do
    if Process.whereis(SegmentIndex) do
      Enum.each(ids, &SegmentIndex.delete_segment(SegmentIndex, &1))

      Enum.each(placements, fn {lsn, offset} ->
        SegmentIndex.insert(SegmentIndex, lsn, target_id, offset)
      end)

      SegmentIndex.flush(SegmentIndex)
    end

    :ok
  end

  # The segment the Writer is appending to must never be rewritten underneath
  # it. Returns nil when the Writer is not running, e.g. in the minimal tree.
  @spec active_segment_id() :: non_neg_integer() | nil
  defp active_segment_id do
    if Process.whereis(Writer) do
      case Writer.info() do
        {:ok, %{current_segment_id: id}} -> id
        _ -> nil
      end
    end
  end

  @spec total_segment_bytes([non_neg_integer()]) :: non_neg_integer()
  defp total_segment_bytes(segment_ids) do
    Enum.reduce(segment_ids, 0, fn segment_id, acc ->
      case SegmentManager.get_segment(segment_id) do
        {:ok, pid} ->
          case Segment.stats(pid) do
            {:ok, stats} -> acc + stats.file_size
            {:error, _} -> acc
          end

        {:error, :not_found} ->
          acc
      end
    end)
  end

  @spec file_size(String.t()) :: non_neg_integer()
  defp file_size(path) do
    case FileBackend.file_size(path) do
      {:ok, size} -> size
      {:error, _} -> 0
    end
  end

  # The Writer nests its segment files one level below its own data_dir, and the
  # Compactor is configured with that same data_dir.
  @spec segments_dir(State.t()) :: String.t()
  defp segments_dir(state), do: Path.join(state.data_dir, "segments")

  @spec segment_file_path(String.t(), non_neg_integer()) :: String.t()
  defp segment_file_path(segments_dir, segment_id) do
    filename = :io_lib.format("segment_~18..0B.wal", [segment_id]) |> IO.iodata_to_binary()
    Path.join(segments_dir, filename)
  end

  @spec read_entries_from_segments([non_neg_integer()]) ::
          {:ok, [term()]} | {:error, term()}
  defp read_entries_from_segments(segment_ids) do
    entries =
      Enum.flat_map(segment_ids, fn segment_id ->
        case SegmentManager.get_segment(segment_id) do
          {:ok, segment_pid} ->
            case Segment.read_all(segment_pid) do
              {:ok, segment_entries} ->
                segment_entries

              {:error, reason} ->
                Logger.warning("Failed to read segment #{segment_id}: #{inspect(reason)}")
                []
            end

          {:error, :not_found} ->
            Logger.warning("Segment #{segment_id} not found")
            []
        end
      end)

    {:ok, entries}
  end
end
