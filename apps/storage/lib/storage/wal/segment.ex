defmodule Storage.WAL.Segment do
  @moduledoc """
  Manages a single WAL segment file.

  A segment is an append-only file containing a sequence of log entries.
  Each segment has a unique ID and maintains a range of LSNs.

  ## Segment File Format

  ### Header (256 bytes):
  - Magic: "SHANGHAI_WAL\\0" (16 bytes)
  - Version: 1 (4 bytes)
  - Segment ID: uint64 (8 bytes)
  - Start LSN: uint64 (8 bytes)
  - Checksum: uint32 (4 bytes)
  - Reserved (216 bytes)

  ### Entry Format (per entry):
  - Length: uint32 (4 bytes)
  - LSN: uint64 (8 bytes)
  - Checksum: uint32 (4 bytes)
  - Payload: ETF binary (variable)

  ## State Lifecycle

  1. **Active**: Accepting writes
  2. **Sealed**: Read-only, no more writes

  ## Examples

      iex> {:ok, pid} = Segment.start_link(segment_id: 1, start_lsn: 100, path: "/tmp/segment_1.wal")
      iex> entry = %CoreDomain.Types.LogEntry{lsn: 100, data: "test"}
      iex> {:ok, offset} = Segment.append_entry(pid, entry)
      iex> {:ok, ^entry} = Segment.read_entry(pid, offset)
      iex> :ok = Segment.seal(pid)
  """

  use GenServer
  require Logger

  alias Storage.Persistence.{FileBackend, Serializer}
  alias CoreDomain.Entities.LogEntry

  @magic "SHANGHAI_WAL\0"
  @version 1
  @header_size 256

  @type segment_id :: non_neg_integer()
  @type offset :: non_neg_integer()
  @type state :: %{
          segment_id: segment_id(),
          start_lsn: non_neg_integer(),
          path: String.t(),
          file: File.io_device() | nil,
          sealed: boolean(),
          current_offset: offset(),
          entry_count: non_neg_integer()
        }

  ## Client API

  @doc """
  Starts a segment GenServer.

  ## Options

  - `:segment_id` - Unique segment identifier
  - `:start_lsn` - First LSN in this segment
  - `:path` - File path for the segment
  - `:create` - Whether to create new segment (default: true)

  ## Examples

      iex> Segment.start_link(segment_id: 1, start_lsn: 0, path: "/tmp/seg1.wal")
      {:ok, pid}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Appends a log entry to the segment.

  Returns the byte offset where the entry was written.

  ## Examples

      iex> entry = %LogEntry{lsn: 100, data: "test"}
      iex> Segment.append_entry(pid, entry)
      {:ok, 256}
  """
  @spec append_entry(pid(), LogEntry.t()) :: {:ok, offset()} | {:error, term()}
  def append_entry(pid, %LogEntry{} = entry) do
    GenServer.call(pid, {:append_entry, entry})
  end

  @doc """
  Reads a log entry at the given byte offset.

  ## Examples

      iex> Segment.read_entry(pid, 256)
      {:ok, %LogEntry{}}
  """
  @spec read_entry(pid(), offset()) :: {:ok, LogEntry.t()} | {:error, term()}
  def read_entry(pid, offset) do
    GenServer.call(pid, {:read_entry, offset})
  end

  @doc """
  Seals the segment, making it read-only.

  After sealing, no more entries can be appended.

  ## Examples

      iex> Segment.seal(pid)
      :ok
  """
  @spec seal(pid()) :: :ok | {:error, term()}
  def seal(pid) do
    GenServer.call(pid, :seal)
  end

  @doc """
  Gets current segment information.

  ## Examples

      iex> Segment.info(pid)
      {:ok, %{segment_id: 1, sealed: false, entry_count: 10}}
  """
  @spec info(pid()) :: {:ok, map()}
  def info(pid) do
    GenServer.call(pid, :info)
  end

  @doc """
  Closes the segment file and stops the GenServer.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    segment_id = Keyword.fetch!(opts, :segment_id)
    start_lsn = Keyword.fetch!(opts, :start_lsn)
    path = Keyword.fetch!(opts, :path)
    create = Keyword.get(opts, :create, true)

    state = %{
      segment_id: segment_id,
      start_lsn: start_lsn,
      path: path,
      file: nil,
      sealed: false,
      current_offset: @header_size,
      entry_count: 0
    }

    case initialize_segment(state, create) do
      {:ok, new_state} ->
        Logger.info("Segment #{segment_id} initialized at #{path}")
        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to initialize segment #{segment_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append_entry, _entry}, _from, %{sealed: true} = state) do
    {:reply, {:error, :segment_sealed}, state}
  end

  def handle_call({:append_entry, entry}, _from, state) do
    case append_entry_impl(entry, state) do
      {:ok, offset, new_state} ->
        {:reply, {:ok, offset}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_entry, offset}, _from, state) do
    result = read_entry_impl(offset, state)
    {:reply, result, state}
  end

  def handle_call(:seal, _from, state) do
    case seal_impl(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      segment_id: state.segment_id,
      start_lsn: state.start_lsn,
      path: state.path,
      sealed: state.sealed,
      current_offset: state.current_offset,
      entry_count: state.entry_count
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.file do
      File.close(state.file)
    end

    :ok
  end

  ## Private Functions

  @spec initialize_segment(state(), boolean()) :: {:ok, state()} | {:error, term()}
  defp initialize_segment(state, true = _create) do
    with :ok <- FileBackend.ensure_directory(Path.dirname(state.path)),
         {:ok, file} <- File.open(state.path, [:write, :read, :binary]),
         :ok <- write_header(file, state),
         :ok <- FileBackend.sync_file(file) do
      {:ok, %{state | file: file}}
    end
  end

  defp initialize_segment(state, false = _create) do
    with {:ok, file} <- File.open(state.path, [:read, :binary]),
         {:ok, header_data} <- validate_existing_header(file, state) do
      # Calculate current offset by seeking to end
      {:ok, end_pos} = :file.position(file, :eof)

      # Reopen in read-write mode for active segments
      File.close(file)
      {:ok, file} = File.open(state.path, [:write, :read, :binary])

      {:ok,
       %{
         state
         | file: file,
           current_offset: end_pos,
           sealed: header_data.sealed,
           entry_count: header_data.entry_count
       }}
    end
  end

  @spec write_header(File.io_device(), state()) :: :ok | {:error, term()}
  defp write_header(file, state) do
    # Build header components
    magic_padded = String.pad_trailing(@magic, 16, <<0>>)
    version_bytes = <<@version::32>>
    segment_id_bytes = <<state.segment_id::64>>
    start_lsn_bytes = <<state.start_lsn::64>>

    # Compute checksum over metadata
    metadata = magic_padded <> version_bytes <> segment_id_bytes <> start_lsn_bytes
    checksum = Serializer.compute_checksum(metadata)
    checksum_bytes = <<checksum::32>>

    # Reserved space (216 bytes)
    reserved = String.duplicate(<<0>>, 216)

    # Combine all parts
    header = metadata <> checksum_bytes <> reserved

    # Verify header size
    if byte_size(header) != @header_size do
      {:error, {:invalid_header_size, byte_size(header)}}
    else
      case IO.binwrite(file, header) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec validate_existing_header(File.io_device(), state()) ::
          {:ok, map()} | {:error, term()}
  defp validate_existing_header(file, state) do
    case IO.binread(file, @header_size) do
      {:error, reason} ->
        {:error, {:header_read_failed, reason}}

      header when byte_size(header) != @header_size ->
        {:error, {:invalid_header_size, byte_size(header)}}

      header ->
        # Parse header
        <<magic::binary-size(16), version::32, segment_id::64, start_lsn::64, checksum::32,
          _reserved::binary>> = header

        # Validate magic
        magic_str = String.trim_trailing(magic, <<0>>)

        if magic_str != String.trim_trailing(@magic, <<0>>) do
          {:error, {:invalid_magic, magic_str}}
        else
          # Validate checksum
          metadata =
            <<magic::binary-size(16), version::32, segment_id::64, start_lsn::64>>

          computed_checksum = Serializer.compute_checksum(metadata)

          if checksum != computed_checksum do
            {:error, :header_checksum_mismatch}
          else
            # Validate segment ID and LSN match
            if segment_id != state.segment_id or start_lsn != state.start_lsn do
              {:error, {:segment_mismatch, segment_id, start_lsn}}
            else
              {:ok, %{sealed: false, entry_count: 0}}
            end
          end
        end
    end
  end

  @spec append_entry_impl(LogEntry.t(), state()) ::
          {:ok, offset(), state()} | {:error, term()}
  defp append_entry_impl(entry, state) do
    # Serialize the entry
    with {:ok, payload} <- Serializer.encode(entry) do
      # Build entry format: [length][lsn][checksum][payload]
      length = byte_size(payload)
      lsn_value = entry.lsn.value
      checksum = Serializer.compute_checksum(payload)

      entry_bytes =
        <<length::32, lsn_value::64, checksum::32, payload::binary>>

      # Get current offset before write
      write_offset = state.current_offset

      # Write to file
      case :file.pwrite(state.file, write_offset, entry_bytes) do
        :ok ->
          # Sync to disk
          case FileBackend.sync_file(state.file) do
            :ok ->
              new_state = %{
                state
                | current_offset: write_offset + byte_size(entry_bytes),
                  entry_count: state.entry_count + 1
              }

              {:ok, write_offset, new_state}

            {:error, reason} ->
              {:error, {:sync_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:write_failed, reason}}
      end
    end
  end

  @spec read_entry_impl(offset(), state()) :: {:ok, LogEntry.t()} | {:error, term()}
  defp read_entry_impl(offset, state) do
    # Read entry header first (length + lsn + checksum = 16 bytes)
    case :file.pread(state.file, offset, 16) do
      {:ok, <<length::32, lsn::64, stored_checksum::32>>} ->
        # Now read the payload
        case :file.pread(state.file, offset + 16, length) do
          {:ok, payload} ->
            # Validate checksum
            computed_checksum = Serializer.compute_checksum(payload)

            if stored_checksum != computed_checksum do
              {:error, :entry_checksum_mismatch}
            else
              # Deserialize payload
              case Serializer.decode(payload) do
                {:ok, entry} ->
                  # Verify LSN matches
                  if entry.lsn.value != lsn do
                    {:error, {:lsn_mismatch, entry.lsn.value, lsn}}
                  else
                    {:ok, entry}
                  end

                {:error, reason} ->
                  {:error, {:deserialization_failed, reason}}
              end
            end

          {:error, reason} ->
            {:error, {:payload_read_failed, reason}}

          :eof ->
            {:error, :incomplete_entry}
        end

      {:error, reason} ->
        {:error, {:header_read_failed, reason}}

      :eof ->
        {:error, :offset_out_of_bounds}

      other ->
        {:error, {:unexpected_read_result, other}}
    end
  end

  @spec seal_impl(state()) :: {:ok, state()} | {:error, term()}
  defp seal_impl(%{sealed: true} = state) do
    {:ok, state}
  end

  defp seal_impl(state) do
    # Sync one final time
    case FileBackend.sync_file(state.file) do
      :ok ->
        Logger.info("Segment #{state.segment_id} sealed with #{state.entry_count} entries")
        {:ok, %{state | sealed: true}}

      {:error, reason} ->
        {:error, {:seal_sync_failed, reason}}
    end
  end
end
