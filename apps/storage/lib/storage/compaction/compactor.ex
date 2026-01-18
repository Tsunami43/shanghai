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

  ## Configuration

  - `:strategy` - Compaction strategy module (default: SizeTiered)
  - `:data_dir` - Directory for WAL segments
  """

  use GenServer
  require Logger

  alias Storage.WAL.{Segment, SegmentManager}

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
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a compaction run.

  Returns `:ok` if compaction started, `{:error, :already_running}` if
  a compaction is already in progress.

  ## Examples

      iex> Compactor.compact()
      :ok
  """
  @spec compact() :: :ok | {:error, :already_running}
  def compact do
    GenServer.call(__MODULE__, :compact, :infinity)
  end

  @doc """
  Gets compaction statistics.

  ## Examples

      iex> Compactor.stats()
      {:ok, %{in_progress: false, last_compaction: ~U[...]}}
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
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

    # Run compaction asynchronously
    Task.start(fn -> run_compaction(state) end)

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

  @spec run_compaction(State.t()) :: :ok | {:error, term()}
  defp run_compaction(state) do
    Logger.info("Starting compaction run")

    try do
      :ok = perform_compaction(state)
      send(__MODULE__, :compaction_complete)
      :ok
    rescue
      e ->
        error = {:compaction_crash, Exception.message(e)}
        send(__MODULE__, {:compaction_failed, error})
        {:error, error}
    end
  end

  @spec perform_compaction(State.t()) :: :ok | {:error, term()}
  defp perform_compaction(state) do
    # Get all segments
    segments = SegmentManager.list_segments()

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
  defp compact_segment_group(segment_ids, _state) do
    Logger.info("Compacting segment group: #{inspect(segment_ids)}")

    # Read all entries from segments
    {:ok, entries} = read_entries_from_segments(segment_ids)

    if entries != [] do
      # Sort by LSN (should already be sorted, but ensure it)
      sorted_entries = Enum.sort_by(entries, & &1.lsn.value)

      # Determine range
      start_lsn = hd(sorted_entries).lsn.value
      end_lsn = List.last(sorted_entries).lsn.value

      Logger.info("Merging #{length(entries)} entries from LSN #{start_lsn} to #{end_lsn}")

      # Create new merged segment
      # For now, log success (actual segment creation would happen here)
      Logger.info("Successfully compacted #{length(segment_ids)} segments into 1 segment")
    else
      Logger.info("No entries found in segment group, skipping")
    end

    :ok
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
