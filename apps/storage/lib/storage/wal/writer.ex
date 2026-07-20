defmodule Storage.WAL.Writer do
  @moduledoc """
  GenServer responsible for appending entries to the Write-Ahead Log.

  Ensures durability through fsync and manages log segments with automatic rotation.
  All writes go through this process to maintain ordering and atomicity.

  ## Group Commit

  Entries are written to the segment file immediately but the expensive fsync is
  amortized across a batch. A caller is only replied to once its entry is on
  disk, so batching changes *when* fsync happens, never *if*:

  - a batch is flushed as soon as no further append is already queued, so a
    lone writer never waits for a timer
  - under concurrent load the batch grows until `:batch_size` entries or
    `:batch_timeout_ms` elapses, so one fsync covers many writes
  - pending writes are always flushed before a rotation and on shutdown

  A crash before the flush loses the un-fsynced entries, exactly as it would
  without batching: no caller has been told those writes succeeded.

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

  alias CoreDomain.Entities.LogEntry
  alias CoreDomain.Types.{LogSequenceNumber, NodeId}
  alias Storage.Index.SegmentIndex
  alias Storage.Persistence.{FileBackend, Serializer}
  alias Storage.WAL.{Segment, SegmentManager}

  # 64 MB
  @default_segment_size_threshold 64 * 1024 * 1024
  # 1 hour in seconds
  @default_segment_time_threshold 3600
  # Persist metadata every N appends
  @metadata_persist_interval 100
  # Max entries sharing one fsync
  @default_batch_size 100
  # Max time an entry waits for its batch to fill
  @default_batch_timeout_ms 10

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
            append_count: non_neg_integer(),
            batch_size: pos_integer(),
            batch_timeout_ms: non_neg_integer(),
            pending: [{GenServer.from(), non_neg_integer()}],
            flush_timer: reference() | nil
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
      :append_count,
      :batch_size,
      :batch_timeout_ms,
      pending: [],
      flush_timer: nil
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
  Like `append/1`, but returns the assigned LSN directly and raises on error.

  ## Examples

      iex> Writer.append!("my data")
      1
  """
  @spec append!(term()) :: non_neg_integer()
  def append!(data) do
    case append(data) do
      {:ok, lsn} -> lsn
      {:error, reason} -> raise "WAL append failed: #{inspect(reason)}"
    end
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

    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    batch_timeout_ms = Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms)

    segments_dir = Path.join(data_dir, "segments")
    metadata_path = Path.join(data_dir, "wal_metadata.dat")

    :ok = FileBackend.ensure_directory(segments_dir)

    node_id = %NodeId{value: node_id_str}

    # Load metadata, then reconcile with the actual segments. The metadata file
    # is only persisted periodically/at shutdown, so after a crash it can be
    # missing or stale; the segment index (rebuilt from the segments on its own
    # start-up) is authoritative for how far the log actually got.
    {meta_lsn, meta_segment_id} = load_metadata(metadata_path)
    {current_lsn, current_segment_id} = recover_position(meta_lsn, meta_segment_id)

    # Reopen every existing segment (not just the active one) so historical reads
    # after a restart work, then open/create the current segment as the writable
    # one. Existing segments open in recovery mode (create: false) and resume at
    # end-of-file rather than overwriting the records already on disk.
    reopen_older_segments(segments_dir, current_segment_id)
    segment_path = segment_file_path(segments_dir, current_segment_id)
    create = not FileBackend.file_exists?(segment_path)

    case SegmentManager.start_segment(current_segment_id, current_lsn, segment_path,
           create: create
         ) do
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
          append_count: 0,
          batch_size: batch_size,
          batch_timeout_ms: batch_timeout_ms,
          pending: [],
          flush_timer: nil
        }

        Logger.info("WAL Writer initialized at LSN #{current_lsn}, segment #{current_segment_id}")

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start initial segment: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, data}, from, state) do
    # Create log entry with next LSN
    lsn = state.current_lsn
    lsn_struct = LogSequenceNumber.new(lsn)

    entry = LogEntry.new(lsn_struct, data, state.node_id, %{})

    # Write now, fsync with the batch. `Segment.append_entry_no_sync/2` emits the
    # `[:shanghai, :storage, :wal, :write]` telemetry at the point of the actual
    # disk write, and the batch's `Segment.sync/1` emits the `:sync` event, so
    # the Writer does not emit either here.
    case Segment.append_entry_no_sync(state.current_segment_pid, entry) do
      {:ok, offset} ->
        # Update index
        :ok = SegmentIndex.insert(SegmentIndex, lsn, state.current_segment_id, offset)

        # Increment LSN and append count, and queue the caller's reply until the
        # entry has been fsynced.
        new_state = %{
          state
          | current_lsn: lsn + 1,
            append_count: state.append_count + 1,
            pending: [{from, lsn} | state.pending]
        }

        {:noreply, new_state |> maybe_flush() |> maybe_rotate() |> maybe_persist_metadata()}

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
  def handle_info(:flush_timeout, state) do
    {:noreply, state |> flush_pending() |> maybe_rotate()}
  end

  @impl true
  def terminate(_reason, state) do
    # Never leave an acknowledged-but-unsynced write behind: callers are still
    # blocked on their reply and the entries are not yet durable.
    state = flush_pending(state)

    # Final metadata persist
    persist_metadata(state)
    Logger.info("WAL Writer shutting down at LSN #{state.current_lsn}")
    :ok
  end

  ## Private Functions

  # Group commit: flush as soon as nothing else is queued, so a lone writer
  # never waits on the timer, and cap the batch under concurrent load. When the
  # batch stays open, a timer bounds how long the oldest entry waits.
  @spec maybe_flush(State.t()) :: State.t()
  defp maybe_flush(state) do
    cond do
      state.pending == [] -> state
      mailbox_empty?() -> flush_pending(state)
      length(state.pending) >= state.batch_size -> flush_pending(state)
      true -> ensure_flush_timer(state)
    end
  end

  @spec mailbox_empty?() :: boolean()
  defp mailbox_empty? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, 0} -> true
      _ -> false
    end
  end

  @spec ensure_flush_timer(State.t()) :: State.t()
  defp ensure_flush_timer(%State{flush_timer: nil} = state) do
    timer = Process.send_after(self(), :flush_timeout, state.batch_timeout_ms)
    %{state | flush_timer: timer}
  end

  defp ensure_flush_timer(state), do: state

  # fsyncs once for the whole batch, then releases every waiting caller. A failed
  # fsync means none of these writes are durable, so they all report an error.
  @spec flush_pending(State.t()) :: State.t()
  defp flush_pending(%State{pending: []} = state), do: cancel_flush_timer(state)

  defp flush_pending(state) do
    result = Segment.sync(state.current_segment_pid)

    if match?({:error, _}, result) do
      Logger.error("Failed to sync WAL batch: #{inspect(result)}")
    end

    state.pending
    |> Enum.reverse()
    |> Enum.each(fn {from, lsn} ->
      case result do
        :ok -> GenServer.reply(from, {:ok, lsn})
        {:error, reason} -> GenServer.reply(from, {:error, {:sync_failed, reason}})
      end
    end)

    cancel_flush_timer(%{state | pending: []})
  end

  @spec cancel_flush_timer(State.t()) :: State.t()
  defp cancel_flush_timer(%State{flush_timer: nil} = state), do: state

  defp cancel_flush_timer(state) do
    Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: nil}
  end

  # Rotation retargets the segment that `flush_pending/1` fsyncs, so any queued
  # write must be made durable in the old segment first.
  @spec maybe_rotate(State.t()) :: State.t()
  defp maybe_rotate(state) do
    current_time = System.monotonic_time(:second)

    if check_size_threshold(state) or check_time_threshold(state, current_time) do
      state |> flush_pending() |> rotate_segment(current_time)
    else
      state
    end
  end

  @spec maybe_persist_metadata(State.t()) :: State.t()
  defp maybe_persist_metadata(state) do
    if rem(state.append_count, @metadata_persist_interval) == 0 do
      persist_metadata(state)
    end

    state
  end

  # Reconciles the loaded metadata with the segment index (which rebuilds itself
  # from the segments on start-up). When the index holds an LSN at or beyond the
  # metadata's, the metadata is missing/stale after a crash, so the next write
  # position is one past the highest indexed LSN, in the segment that holds it.
  @spec recover_position(non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp recover_position(meta_lsn, meta_segment_id) do
    case index_max_lsn() do
      max_lsn when is_integer(max_lsn) and max_lsn >= meta_lsn ->
        segment_id = index_segment_of(max_lsn, meta_segment_id)

        Logger.info(
          "WAL recovering position from segments: LSN #{meta_lsn} -> #{max_lsn + 1}, " <>
            "segment #{segment_id}"
        )

        {max_lsn + 1, segment_id}

      _ ->
        {meta_lsn, meta_segment_id}
    end
  end

  defp index_max_lsn do
    SegmentIndex.max_lsn()
  catch
    :exit, _ -> nil
  end

  defp index_segment_of(lsn, default_segment_id) do
    case SegmentIndex.lookup(lsn) do
      {:ok, {segment_id, _offset}} -> segment_id
      _ -> default_segment_id
    end
  end

  # Reopens every existing segment other than the current one (read-only, from
  # its file) so records in older, already-rotated segments remain readable after
  # a restart. A segment that fails to reopen is logged and skipped.
  defp reopen_older_segments(segments_dir, current_segment_id) do
    for id <- existing_segment_ids(segments_dir), id != current_segment_id do
      path = segment_file_path(segments_dir, id)

      case SegmentManager.start_segment(id, 0, path, create: false) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("Could not reopen segment #{id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp existing_segment_ids(segments_dir) do
    case FileBackend.list_files(segments_dir, "segment_*.wal") do
      {:ok, files} ->
        files
        |> Enum.map(&parse_segment_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp parse_segment_id(path) do
    case Regex.run(~r/segment_(\d+)\.wal$/, Path.basename(path)) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

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

  @spec check_size_threshold(State.t()) :: boolean()
  defp check_size_threshold(state) do
    {:ok, info} = Segment.info(state.current_segment_pid)
    # Calculate approximate size from current offset
    size = info.current_offset
    size >= state.segment_size_threshold
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
