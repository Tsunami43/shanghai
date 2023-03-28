defmodule Storage.Index.SegmentIndex do
  @moduledoc """
  In-memory index mapping LSN to segment location with disk persistence.

  Maintains an ETS table for fast lookups: LSN → {segment_id, offset}
  Periodically flushes to disk for crash recovery.

  ## Persistence Strategy

  - Flush to disk every N inserts (threshold)
  - Flush to disk every M seconds (interval)
  - On demand via explicit flush/0 call

  ## Recovery

  If index file is corrupted or missing, can rebuild from WAL segments by scanning
  all segment files and reconstructing the index.

  ## Examples

      iex> {:ok, pid} = SegmentIndex.start_link(data_dir: "/tmp/index")
      iex> :ok = SegmentIndex.insert(pid, 100, 1, 256)
      iex> {:ok, {1, 256}} = SegmentIndex.lookup(pid, 100)
  """

  use GenServer
  require Logger

  alias Storage.Persistence.{FileBackend, Serializer}

  @flush_threshold 1000
  @flush_interval 10_000

  @type lsn :: non_neg_integer()
  @type segment_id :: non_neg_integer()
  @type offset :: non_neg_integer()
  @type index_entry :: {segment_id(), offset()}

  @type state :: %{
          table: :ets.tid(),
          data_dir: String.t(),
          index_path: String.t(),
          backup_path: String.t(),
          insert_count: non_neg_integer(),
          last_flush: integer()
        }

  ## Client API

  @doc """
  Starts the SegmentIndex GenServer.

  ## Options

  - `:data_dir` - Directory to store index files
  - `:flush_threshold` - Number of inserts before auto-flush (default: #{@flush_threshold})
  - `:flush_interval` - Time in ms between flushes (default: #{@flush_interval})
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Inserts an index entry mapping LSN to segment location.

  ## Examples

      iex> SegmentIndex.insert(pid, 100, 1, 256)
      :ok
  """
  @spec insert(GenServer.server(), lsn(), segment_id(), offset()) :: :ok
  def insert(server \\ __MODULE__, lsn, segment_id, offset) do
    GenServer.call(server, {:insert, lsn, segment_id, offset})
  end

  @doc """
  Looks up segment location for a given LSN.

  Returns {:ok, {segment_id, offset}} if found, {:error, :not_found} otherwise.

  ## Examples

      iex> SegmentIndex.lookup(pid, 100)
      {:ok, {1, 256}}

      iex> SegmentIndex.lookup(pid, 999)
      {:error, :not_found}
  """
  @spec lookup(GenServer.server(), lsn()) :: {:ok, index_entry()} | {:error, :not_found}
  def lookup(server \\ __MODULE__, lsn) do
    GenServer.call(server, {:lookup, lsn})
  end

  @doc """
  Flushes the index to disk immediately.

  ## Examples

      iex> SegmentIndex.flush(pid)
      :ok
  """
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  end

  @doc """
  Gets index statistics.

  Returns a map with:
  - :entry_count - Number of entries in index
  - :insert_count - Number of inserts since last flush
  - :last_flush - Timestamp of last flush

  ## Examples

      iex> SegmentIndex.stats(pid)
      {:ok, %{entry_count: 1000, insert_count: 50, last_flush: 1234567890}}
  """
  @spec stats(GenServer.server()) :: {:ok, map()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc """
  Deletes all entries for a specific segment.

  Used during compaction when segments are merged/deleted.

  ## Examples

      iex> SegmentIndex.delete_segment(pid, 1)
      :ok
  """
  @spec delete_segment(GenServer.server(), segment_id()) :: :ok
  def delete_segment(server \\ __MODULE__, segment_id) do
    GenServer.call(server, {:delete_segment, segment_id})
  end

  @doc """
  Rebuilds index from WAL segment files.

  Scans all segments and reconstructs the LSN → location mapping.
  This is used for crash recovery when the index file is corrupted.

  ## Examples

      iex> SegmentIndex.rebuild_from_segments(pid, "/data/wal/segments")
      {:ok, 5000}
  """
  @spec rebuild_from_segments(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_from_segments(server \\ __MODULE__, segments_dir) do
    GenServer.call(server, {:rebuild_from_segments, segments_dir}, :infinity)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    flush_threshold = Keyword.get(opts, :flush_threshold, @flush_threshold)
    flush_interval = Keyword.get(opts, :flush_interval, @flush_interval)

    index_path = Path.join(data_dir, "segment_index.dat")
    backup_path = Path.join(data_dir, "segment_index.backup.dat")

    # Ensure directory exists
    :ok = FileBackend.ensure_directory(data_dir)

    # Create ETS table
    table = :ets.new(:segment_index, [:set, :protected, read_concurrency: true])

    state = %{
      table: table,
      data_dir: data_dir,
      index_path: index_path,
      backup_path: backup_path,
      insert_count: 0,
      last_flush: System.monotonic_time(:millisecond),
      flush_threshold: flush_threshold,
      flush_interval: flush_interval
    }

    # Load index from disk
    state = load_index(state)

    # Schedule periodic flush
    schedule_flush(flush_interval)

    Logger.info("SegmentIndex initialized with #{:ets.info(table, :size)} entries")

    {:ok, state}
  end

  @impl true
  def handle_call({:insert, lsn, segment_id, offset}, _from, state) do
    :ets.insert(state.table, {lsn, {segment_id, offset}})

    new_state = %{state | insert_count: state.insert_count + 1}

    # Auto-flush if threshold reached
    new_state =
      if new_state.insert_count >= state.flush_threshold do
        case flush_impl(new_state) do
          {:ok, flushed_state} ->
            flushed_state

          {:error, reason} ->
            Logger.warning("Auto-flush failed: #{inspect(reason)}")
            new_state
        end
      else
        new_state
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:lookup, lsn}, _from, state) do
    result =
      case :ets.lookup(state.table, lsn) do
        [{^lsn, location}] -> {:ok, location}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:flush, _from, state) do
    case flush_impl(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      entry_count: :ets.info(state.table, :size),
      insert_count: state.insert_count,
      last_flush: state.last_flush
    }

    {:reply, {:ok, stats}, state}
  end

  def handle_call({:delete_segment, segment_id}, _from, state) do
    # Find all entries for this segment and delete them
    match_spec = [{{:"$1", {segment_id, :"$2"}}, [], [:"$1"]}]
    lsns = :ets.select(state.table, match_spec)

    Enum.each(lsns, fn lsn ->
      :ets.delete(state.table, lsn)
    end)

    Logger.info("Deleted #{length(lsns)} index entries for segment #{segment_id}")

    {:reply, :ok, state}
  end

  def handle_call({:rebuild_from_segments, segments_dir}, _from, state) do
    Logger.info("Rebuilding index from segments in #{segments_dir}")

    case rebuild_impl(state.table, segments_dir) do
      {:ok, count} ->
        Logger.info("Index rebuilt with #{count} entries")
        {:reply, {:ok, count}, %{state | insert_count: 0}}

      {:error, reason} = error ->
        Logger.error("Failed to rebuild index: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:periodic_flush, state) do
    new_state =
      case flush_impl(state) do
        {:ok, flushed_state} ->
          flushed_state

        {:error, reason} ->
          Logger.warning("Periodic flush failed: #{inspect(reason)}")
          state
      end

    schedule_flush(state.flush_interval)

    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    # Final flush on shutdown
    case flush_impl(state) do
      {:ok, _} -> Logger.info("SegmentIndex flushed on shutdown")
      {:error, reason} -> Logger.warning("Failed to flush on shutdown: #{inspect(reason)}")
    end

    :ok
  end

  ## Private Functions

  @spec load_index(state()) :: state()
  defp load_index(state) do
    cond do
      FileBackend.file_exists?(state.index_path) ->
        case load_from_file(state.table, state.index_path) do
          {:ok, count} ->
            Logger.info("Loaded #{count} index entries from #{state.index_path}")
            state

          {:error, reason} ->
            Logger.warning("Failed to load index from primary file: #{inspect(reason)}")
            load_from_backup(state)
        end

      FileBackend.file_exists?(state.backup_path) ->
        Logger.info("Primary index not found, loading from backup")
        load_from_backup(state)

      true ->
        Logger.info("No existing index found, starting fresh")
        state
    end
  end

  @spec load_from_backup(state()) :: state()
  defp load_from_backup(state) do
    case load_from_file(state.table, state.backup_path) do
      {:ok, count} ->
        Logger.info("Loaded #{count} index entries from backup")
        state

      {:error, reason} ->
        Logger.warning("Failed to load from backup: #{inspect(reason)}")
        state
    end
  end

  @spec load_from_file(:ets.tid(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp load_from_file(table, path) do
    with {:ok, binary} <- FileBackend.read_file(path),
         {:ok, entries} <- Serializer.decode_with_checksum(binary) do
      # Clear existing entries
      :ets.delete_all_objects(table)

      # Insert all entries
      :ets.insert(table, entries)

      {:ok, length(entries)}
    end
  end

  @spec flush_impl(state()) :: {:ok, state()} | {:error, term()}
  defp flush_impl(state) do
    # Get all entries from ETS
    entries = :ets.tab2list(state.table)

    # Serialize with checksum
    with {:ok, binary} <- Serializer.encode_with_checksum(entries),
         # Write to backup first
         :ok <- FileBackend.write_atomic(state.backup_path, binary),
         # Then write to primary
         :ok <- FileBackend.write_atomic(state.index_path, binary) do
      new_state = %{
        state
        | insert_count: 0,
          last_flush: System.monotonic_time(:millisecond)
      }

      {:ok, new_state}
    end
  end

  @spec rebuild_impl(:ets.tid(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp rebuild_impl(table, segments_dir) do
    # Clear existing index
    :ets.delete_all_objects(table)

    # List all .wal files
    with {:ok, files} <- FileBackend.list_files(segments_dir, "*.wal") do
      count =
        Enum.reduce(files, 0, fn segment_path, acc ->
          case scan_segment_file(table, segment_path) do
            {:ok, entries_added} ->
              acc + entries_added

            {:error, reason} ->
              Logger.warning("Failed to scan #{segment_path}: #{inspect(reason)}")
              acc
          end
        end)

      {:ok, count}
    end
  end

  @spec scan_segment_file(:ets.tid(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp scan_segment_file(table, segment_path) do
    # Parse segment_id from filename
    # Format: segment_NNNNNNNNNNNNNNNNNN.wal
    basename = Path.basename(segment_path, ".wal")

    case Regex.run(~r/segment_(\d+)/, basename) do
      [_, segment_id_str] ->
        segment_id = String.to_integer(segment_id_str)
        scan_segment_entries(table, segment_path, segment_id)

      _ ->
        {:error, {:invalid_segment_filename, segment_path}}
    end
  end

  @spec scan_segment_entries(:ets.tid(), String.t(), segment_id()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp scan_segment_entries(table, segment_path, segment_id) do
    with {:ok, file} <- File.open(segment_path, [:read, :binary]) do
      # Skip header (256 bytes)
      :file.position(file, 256)

      count = scan_entries_loop(file, table, segment_id, 256, 0)

      File.close(file)

      {:ok, count}
    end
  end

  @spec scan_entries_loop(File.io_device(), :ets.tid(), segment_id(), offset(), non_neg_integer()) ::
          non_neg_integer()
  defp scan_entries_loop(file, table, segment_id, current_offset, count) do
    case :file.read(file, 16) do
      {:ok, <<length::32, lsn::64, _checksum::32>>} ->
        # Skip payload
        :file.position(file, {:cur, length})

        # Insert index entry
        :ets.insert(table, {lsn, {segment_id, current_offset}})

        # Calculate next offset
        next_offset = current_offset + 16 + length

        scan_entries_loop(file, table, segment_id, next_offset, count + 1)

      :eof ->
        count

      {:error, _reason} ->
        count
    end
  end

  @spec schedule_flush(non_neg_integer()) :: reference()
  defp schedule_flush(interval) do
    Process.send_after(self(), :periodic_flush, interval)
  end
end
