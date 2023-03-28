defmodule Storage.WAL.Reader do
  @moduledoc """
  GenServer responsible for reading entries from the Write-Ahead Log.

  Supports:
  - Random access by LSN using SegmentIndex
  - Sequential scanning (read_range)
  - Segment caching for performance

  ## Examples

      iex> {:ok, entry} = Reader.read(100)
      iex> {:ok, entries} = Reader.read_range(100, 105)
  """

  use GenServer
  require Logger

  alias CoreDomain.Entities.LogEntry
  alias Storage.Index.SegmentIndex
  alias Storage.WAL.{Segment, SegmentManager}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            segment_cache: %{non_neg_integer() => pid()}
          }

    defstruct segment_cache: %{}
  end

  ## Client API

  @doc """
  Starts the Reader GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads a log entry at the given LSN.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Reader.read(100)
      {:ok, %LogEntry{lsn: 100, data: "..."}}

      iex> Reader.read(999999)
      {:error, :not_found}
  """
  @spec read(non_neg_integer()) :: {:ok, LogEntry.t()} | {:error, term()}
  def read(lsn) when is_integer(lsn) do
    GenServer.call(__MODULE__, {:read, lsn})
  end

  @doc """
  Reads log entries from start_lsn up to end_lsn (inclusive).

  Returns `{:ok, entries}` with all found entries in LSN order.

  ## Examples

      iex> Reader.read_range(100, 105)
      {:ok, [%LogEntry{lsn: 100}, %LogEntry{lsn: 101}, ...]}

      iex> Reader.read_range(999, 1000)
      {:ok, []}
  """
  @spec read_range(non_neg_integer(), non_neg_integer()) ::
          {:ok, [LogEntry.t()]} | {:error, term()}
  def read_range(start_lsn, end_lsn) when is_integer(start_lsn) and is_integer(end_lsn) do
    GenServer.call(__MODULE__, {:read_range, start_lsn, end_lsn}, :infinity)
  end

  @doc """
  Gets Reader statistics.

  ## Examples

      iex> Reader.stats()
      {:ok, %{cached_segments: 3}}
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("WAL Reader initialized")

    state = %State{
      segment_cache: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:read, lsn}, _from, state) do
    case read_entry_by_lsn(lsn, state) do
      {:ok, entry, new_state} ->
        {:reply, {:ok, entry}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_range, start_lsn, end_lsn}, _from, state) do
    {:ok, entries, new_state} = read_range_impl(start_lsn, end_lsn, state)
    {:reply, {:ok, entries}, new_state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      cached_segments: map_size(state.segment_cache)
    }

    {:reply, {:ok, stats}, state}
  end

  ## Private Functions

  @spec read_entry_by_lsn(non_neg_integer(), State.t()) ::
          {:ok, LogEntry.t(), State.t()} | {:error, term()}
  defp read_entry_by_lsn(lsn, state) do
    # Lookup LSN in index
    case SegmentIndex.lookup(SegmentIndex, lsn) do
      {:ok, {segment_id, offset}} ->
        # Get or open segment
        case get_or_open_segment(segment_id, state) do
          {:ok, segment_pid, new_state} ->
            # Read entry from segment
            case Segment.read_entry(segment_pid, offset) do
              {:ok, entry} ->
                {:ok, entry, new_state}

              {:error, reason} ->
                Logger.warning("Failed to read entry at LSN #{lsn}: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec read_range_impl(non_neg_integer(), non_neg_integer(), State.t()) ::
          {:ok, [LogEntry.t()], State.t()}
  defp read_range_impl(start_lsn, end_lsn, state) do
    # Read all LSNs in range
    lsns = Enum.to_list(start_lsn..end_lsn)

    {entries, new_state} =
      Enum.reduce(lsns, {[], state}, fn lsn, {acc_entries, acc_state} ->
        case read_entry_by_lsn(lsn, acc_state) do
          {:ok, entry, updated_state} ->
            {[entry | acc_entries], updated_state}

          {:error, :not_found} ->
            # Skip missing entries
            {acc_entries, acc_state}

          {:error, _reason} ->
            # Skip errored entries but log
            {acc_entries, acc_state}
        end
      end)

    # Reverse to maintain LSN order
    {:ok, Enum.reverse(entries), new_state}
  end

  @spec get_or_open_segment(non_neg_integer(), State.t()) ::
          {:ok, pid(), State.t()} | {:error, term()}
  defp get_or_open_segment(segment_id, state) do
    case Map.get(state.segment_cache, segment_id) do
      nil ->
        # Not in cache, get from SegmentManager
        case SegmentManager.get_segment(segment_id) do
          {:ok, pid} ->
            # Add to cache
            new_cache = Map.put(state.segment_cache, segment_id, pid)
            new_state = %{state | segment_cache: new_cache}
            {:ok, pid, new_state}

          {:error, :not_found} ->
            Logger.warning("Segment #{segment_id} not found in SegmentManager")
            {:error, {:segment_not_found, segment_id}}
        end

      pid ->
        # Already in cache
        if Process.alive?(pid) do
          {:ok, pid, state}
        else
          # Cached pid is dead, remove and retry
          new_cache = Map.delete(state.segment_cache, segment_id)
          new_state = %{state | segment_cache: new_cache}
          get_or_open_segment(segment_id, new_state)
        end
    end
  end
end
