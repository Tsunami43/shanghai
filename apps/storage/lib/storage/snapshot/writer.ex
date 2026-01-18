defmodule Storage.Snapshot.Writer do
  @moduledoc """
  Creates point-in-time snapshots of the WAL.

  Snapshots capture all log entries up to a specific LSN, compressed and
  stored in a single file for fast recovery.

  ## Snapshot Format

  - **Data file** (.snap): Compressed ETF binary of all entries
  - **Metadata file** (.meta): Snapshot metadata (LSN, count, checksum, timestamp)

  ## Examples

      iex> {:ok, snapshot_id} = SnapshotWriter.create_snapshot(snapshots_dir, 1000, reader_pid)
      iex> snapshot_id
      "snapshot_20260111_120000_lsn_0000000000001000"
  """

  require Logger

  alias Storage.Persistence.{FileBackend, Serializer}
  alias Storage.WAL.Reader

  @type snapshot_id :: String.t()
  @type snapshot_metadata :: %{
          snapshot_id: snapshot_id(),
          lsn: non_neg_integer(),
          entry_count: non_neg_integer(),
          checksum: non_neg_integer(),
          created_at: DateTime.t(),
          compressed_size: non_neg_integer(),
          uncompressed_size: non_neg_integer()
        }

  @doc """
  Creates a snapshot up to the given LSN.

  Reads all entries from LSN 0 to the given LSN, compresses them, and writes
  to disk with metadata.

  ## Parameters

  - `snapshots_dir` - Directory to store snapshots
  - `lsn` - Last LSN to include in snapshot
  - `reader` - Reader process to read entries from

  ## Returns

  - `{:ok, snapshot_id}` - Success with snapshot ID
  - `{:error, reason}` - Failure reason

  ## Examples

      iex> SnapshotWriter.create_snapshot("/data/snapshots", 1000, reader_pid)
      {:ok, "snapshot_20260111_120000_lsn_0000000000001000"}
  """
  @spec create_snapshot(String.t(), non_neg_integer()) ::
          {:ok, snapshot_id()} | {:error, term()}
  @spec create_snapshot(String.t(), non_neg_integer(), module() | pid()) ::
          {:ok, snapshot_id()} | {:error, term()}
  def create_snapshot(snapshots_dir, lsn, reader \\ Reader) when is_integer(lsn) and lsn >= 0 do
    Logger.info("Creating snapshot up to LSN #{lsn}")

    with :ok <- FileBackend.ensure_directory(snapshots_dir),
         {:ok, entries} <- read_entries_up_to_lsn(lsn, reader),
         {:ok, snapshot_id} <- generate_snapshot_id(lsn),
         {:ok, metadata} <- write_snapshot_files(snapshots_dir, snapshot_id, entries, lsn) do
      Logger.info("Snapshot #{snapshot_id} created with #{metadata.entry_count} entries")
      {:ok, snapshot_id}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create snapshot: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Gets snapshot file paths for a given snapshot ID.

  ## Examples

      iex> SnapshotWriter.snapshot_paths("/data/snapshots", "snapshot_20260111_120000_lsn_0000000000001000")
      {"/data/snapshots/snapshot_20260111_120000_lsn_0000000000001000.snap",
       "/data/snapshots/snapshot_20260111_120000_lsn_0000000000001000.meta"}
  """
  @spec snapshot_paths(String.t(), snapshot_id()) :: {String.t(), String.t()}
  def snapshot_paths(snapshots_dir, snapshot_id) do
    data_path = Path.join(snapshots_dir, "#{snapshot_id}.snap")
    meta_path = Path.join(snapshots_dir, "#{snapshot_id}.meta")
    {data_path, meta_path}
  end

  ## Private Functions

  @spec read_entries_up_to_lsn(non_neg_integer(), pid() | module()) ::
          {:ok, [term()]} | {:error, term()}
  defp read_entries_up_to_lsn(lsn, _reader) do
    # Read from LSN 0 to target LSN (inclusive)
    case Reader.read_range(0, lsn) do
      {:ok, entries} ->
        Logger.debug("Read #{length(entries)} entries for snapshot")
        {:ok, entries}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @spec generate_snapshot_id(non_neg_integer()) :: {:ok, snapshot_id()}
  defp generate_snapshot_id(lsn) do
    # Format: snapshot_YYYYMMDD_HHMMSS_lsn_NNNNNNNNNNNNNNN
    now = DateTime.utc_now()
    date_str = Calendar.strftime(now, "%Y%m%d_%H%M%S")
    lsn_str = String.pad_leading(Integer.to_string(lsn), 16, "0")

    snapshot_id = "snapshot_#{date_str}_lsn_#{lsn_str}"
    {:ok, snapshot_id}
  end

  @spec write_snapshot_files(String.t(), snapshot_id(), [term()], non_neg_integer()) ::
          {:ok, snapshot_metadata()} | {:error, term()}
  defp write_snapshot_files(snapshots_dir, snapshot_id, entries, lsn) do
    {data_path, meta_path} = snapshot_paths(snapshots_dir, snapshot_id)

    with {:ok, uncompressed} <- Serializer.encode(entries),
         {:ok, compressed} <- compress_data(uncompressed),
         checksum = Serializer.compute_checksum(compressed),
         :ok <- FileBackend.write_atomic(data_path, compressed),
         metadata = build_metadata(snapshot_id, lsn, entries, compressed, uncompressed, checksum),
         {:ok, meta_binary} <- Serializer.encode(metadata),
         :ok <- FileBackend.write_atomic(meta_path, meta_binary) do
      {:ok, metadata}
    else
      {:error, reason} ->
        # Cleanup on failure
        File.rm(data_path)
        File.rm(meta_path)
        {:error, {:write_failed, reason}}
    end
  end

  @spec compress_data(binary()) :: {:ok, binary()} | {:error, term()}
  defp compress_data(data) do
    compressed = :zlib.gzip(data)
    {:ok, compressed}
  rescue
    e ->
      {:error, {:compression_failed, Exception.message(e)}}
  end

  @spec build_metadata(
          snapshot_id(),
          non_neg_integer(),
          [term()],
          binary(),
          binary(),
          non_neg_integer()
        ) :: snapshot_metadata()
  defp build_metadata(snapshot_id, lsn, entries, compressed, uncompressed, checksum) do
    %{
      snapshot_id: snapshot_id,
      lsn: lsn,
      entry_count: length(entries),
      checksum: checksum,
      created_at: DateTime.utc_now(),
      compressed_size: byte_size(compressed),
      uncompressed_size: byte_size(uncompressed)
    }
  end
end
