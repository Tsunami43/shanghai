defmodule Storage.WAL.Writer do
  @moduledoc """
  GenServer responsible for appending entries to the Write-Ahead Log.

  Ensures durability through fsync and manages log segments with automatic rotation.
  All writes go through this process to maintain ordering and atomicity.

  ## Rotation Strategy

  Segments rotate when EITHER condition is met:
  - Size >= 64 MB (configurable)
  - Time >= 1 hour (configurable)

  ## Examples

      iex> {:ok, lsn} = Writer.append("data")
      iex> {:ok, info} = Writer.info()
      iex> info.current_lsn
      1
  """

  use GenServer
  require Logger

  alias CoreDomain.Types.{LogSequenceNumber, NodeId}
  alias CoreDomain.Entities.LogEntry
  alias Storage.WAL.{Segment, SegmentManager}
  alias Storage.Index.SegmentIndex
  alias Storage.Persistence.{FileBackend, Serializer}

  # 64 MB
  @default_segment_size_threshold 64 * 1024 * 1024
  # 1 hour in seconds
  @default_segment_time_threshold 3600
  # Persist metadata every N appends
  @metadata_persist_interval 100

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            current_lsn: non_neg_integer(),
            current_segment_id: non_neg_integer(),
            current_segment_pid: pid() | nil,
            segment_start_time: integer(),
            data_dir: String.t(),
            segments_dir: String.t(),
            metadata_path: String.t(),
            node_id: NodeId.t(),
            segment_size_threshold: non_neg_integer(),
            segment_time_threshold: non_neg_integer(),
            append_count: non_neg_integer()
          }

    defstruct [
      :current_lsn,
      :current_segment_id,
      :current_segment_pid,
      :segment_start_time,
      :data_dir,
      :segments_dir,
      :metadata_path,
      :node_id,
      :segment_size_threshold,
      :segment_time_threshold,
      :append_count
    ]
  end

  ## Client API

  @doc """
  Starts the Writer GenServer.

  ## Options

  - `:data_dir` - Root directory for WAL data (required)
  - `:node_id` - Node identifier (default: "node1")
  - `:segment_size_threshold` - Max segment size in bytes (default: 64 MB)
  - `:segment_time_threshold` - Max segment age in seconds (default: 3600)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends data to the WAL.

  Returns `{:ok, lsn}` with the assigned LSN on success.

  ## Examples

      iex> Writer.append("my data")
      {:ok, 1}
  """
  @spec append(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(data) do
    GenServer.call(__MODULE__, {:append, data})
  end

  @doc """
  Gets current Writer information.

  ## Examples

      iex> Writer.info()
      {:ok, %{current_lsn: 100, current_segment_id: 2}}
  """
  @spec info() :: {:ok, map()}
  def info do
    GenServer.call(__MODULE__, :info)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    node_id_str = Keyword.get(opts, :node_id, "node1")

    segment_size_threshold =
      Keyword.get(opts, :segment_size_threshold, @default_segment_size_threshold)

    segment_time_threshold =
      Keyword.get(opts, :segment_time_threshold, @default_segment_time_threshold)

    segments_dir = Path.join(data_dir, "segments")
    metadata_path = Path.join(data_dir, "wal_metadata.dat")

    :ok = FileBackend.ensure_directory(segments_dir)

    node_id = %NodeId{value: node_id_str}

    # Load or create metadata
    {current_lsn, current_segment_id} = load_metadata(metadata_path)

    # Start current segment
    segment_path = segment_file_path(segments_dir, current_segment_id)

    case SegmentManager.start_segment(current_segment_id, current_lsn, segment_path) do
      {:ok, segment_pid} ->
        state = %State{
          current_lsn: current_lsn,
          current_segment_id: current_segment_id,
          current_segment_pid: segment_pid,
          segment_start_time: System.monotonic_time(:second),
          data_dir: data_dir,
          segments_dir: segments_dir,
          metadata_path: metadata_path,
          node_id: node_id,
          segment_size_threshold: segment_size_threshold,
          segment_time_threshold: segment_time_threshold,
          append_count: 0
        }

        Logger.info("WAL Writer initialized at LSN #{current_lsn}, segment #{current_segment_id}")

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start initial segment: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, data}, _from, state) do
    # Create log entry with next LSN
    lsn = state.current_lsn
    lsn_struct = LogSequenceNumber.new(lsn)

    entry = LogEntry.new(lsn_struct, data, state.node_id, %{})

    # Append to current segment
    case Segment.append_entry(state.current_segment_pid, entry) do
      {:ok, offset} ->
        # Update index
        :ok = SegmentIndex.insert(SegmentIndex, lsn, state.current_segment_id, offset)

        # Increment LSN and append count
        new_state = %{
          state
          | current_lsn: lsn + 1,
            append_count: state.append_count + 1
        }

        # Check if we need to rotate (cache current time for checks)
        current_time = System.monotonic_time(:second)
        new_state = check_and_rotate(new_state, current_time)

        # Periodically persist metadata
        new_state =
          if rem(new_state.append_count, @metadata_persist_interval) == 0 do
            persist_metadata(new_state)
            new_state
          else
            new_state
          end

        {:reply, {:ok, lsn}, new_state}

      {:error, reason} ->
        Logger.error("Failed to append entry: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      current_lsn: state.current_lsn,
      current_segment_id: state.current_segment_id,
      append_count: state.append_count,
      segment_start_time: state.segment_start_time
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Final metadata persist
    persist_metadata(state)
    Logger.info("WAL Writer shutting down at LSN #{state.current_lsn}")
    :ok
  end

  ## Private Functions

  @spec load_metadata(String.t()) :: {non_neg_integer(), non_neg_integer()}
  defp load_metadata(metadata_path) do
    case FileBackend.read_file(metadata_path) do
      {:ok, binary} ->
        case Serializer.decode(binary) do
          {:ok, %{current_lsn: lsn, current_segment_id: seg_id}} ->
            Logger.info("Loaded WAL metadata: LSN=#{lsn}, segment=#{seg_id}")
            {lsn, seg_id}

          {:error, reason} ->
            Logger.warning("Failed to decode metadata: #{inspect(reason)}, starting fresh")
            {0, 1}
        end

      {:error, :file_not_found} ->
        Logger.info("No existing WAL metadata, starting fresh")
        {0, 1}

      {:error, reason} ->
        Logger.warning("Failed to read metadata: #{inspect(reason)}, starting fresh")
        {0, 1}
    end
  end

  @spec persist_metadata(State.t()) :: :ok | {:error, term()}
  defp persist_metadata(state) do
    metadata = %{
      current_lsn: state.current_lsn,
      current_segment_id: state.current_segment_id,
      timestamp: DateTime.utc_now()
    }

    case Serializer.encode(metadata) do
      {:ok, binary} ->
        case FileBackend.write_atomic(state.metadata_path, binary) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to persist metadata: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to encode metadata: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec check_and_rotate(State.t(), integer()) :: State.t()
  defp check_and_rotate(state, current_time) do
    should_rotate =
      check_size_threshold(state) or check_time_threshold(state, current_time)

    if should_rotate do
      rotate_segment(state, current_time)
    else
      state
    end
  end

  @spec check_size_threshold(State.t()) :: boolean()
  defp check_size_threshold(state) do
    case Segment.info(state.current_segment_pid) do
      {:ok, info} ->
        # Calculate approximate size from current offset
        size = info.current_offset
        size >= state.segment_size_threshold

      {:error, _} ->
        false
    end
  end

  @spec check_time_threshold(State.t(), integer()) :: boolean()
  defp check_time_threshold(state, current_time) do
    elapsed = current_time - state.segment_start_time
    elapsed >= state.segment_time_threshold
  end

  @spec rotate_segment(State.t(), integer()) :: State.t()
  defp rotate_segment(state, current_time) do
    Logger.info("Rotating segment #{state.current_segment_id} at LSN #{state.current_lsn}")

    # Seal current segment
    :ok = Segment.seal(state.current_segment_pid)

    # Start new segment
    new_segment_id = state.current_segment_id + 1
    new_segment_path = segment_file_path(state.segments_dir, new_segment_id)

    case SegmentManager.start_segment(new_segment_id, state.current_lsn, new_segment_path) do
      {:ok, new_pid} ->
        # Persist metadata with new segment info
        new_state = %{
          state
          | current_segment_id: new_segment_id,
            current_segment_pid: new_pid,
            segment_start_time: current_time
        }

        persist_metadata(new_state)

        Logger.info("Started new segment #{new_segment_id}")

        new_state

      {:error, reason} ->
        Logger.error("Failed to start new segment: #{inspect(reason)}")
        # Keep current segment, don't rotate
        state
    end
  end

  @spec segment_file_path(String.t(), non_neg_integer()) :: String.t()
  defp segment_file_path(segments_dir, segment_id) do
    # Format: segment_0000000000000001.wal
    # Use :io_lib.format for efficient zero-padded formatting
    filename = :io_lib.format("segment_~18..0B.wal", [segment_id]) |> IO.iodata_to_binary()
    Path.join(segments_dir, filename)
  end
end
