defmodule Storage.Snapshot.Reader do
  @moduledoc """
  Reads and validates snapshots.

  Loads snapshot data, validates checksums, decompresses, and returns entries.

  ## Examples

      iex> {:ok, entries} = SnapshotReader.read_snapshot(snapshots_dir, snapshot_id)
      iex> length(entries)
      1000
  """

  require Logger

  alias Storage.Persistence.{FileBackend, Serializer}
  alias Storage.Snapshot.Writer

  @type snapshot_id :: String.t()
  @type snapshot_info :: %{
          snapshot_id: snapshot_id(),
          lsn: non_neg_integer(),
          entry_count: non_neg_integer(),
          created_at: DateTime.t(),
          compressed_size: non_neg_integer(),
          uncompressed_size: non_neg_integer()
        }

  @doc """
  Reads a snapshot and returns all entries.

  Validates checksum, decompresses, and deserializes entries.

  ## Parameters

  - `snapshots_dir` - Directory containing snapshots
  - `snapshot_id` - ID of snapshot to read

  ## Returns

  - `{:ok, entries}` - List of log entries
  - `{:error, reason}` - Failure reason

  ## Examples

      iex> SnapshotReader.read_snapshot("/data/snapshots", "snapshot_20260111_120000_lsn_0000000000001000")
      {:ok, [%LogEntry{}, ...]}
  """
  @spec read_snapshot(String.t(), snapshot_id()) :: {:ok, [term()]} | {:error, term()}
  def read_snapshot(snapshots_dir, snapshot_id) do
    Logger.info("Reading snapshot #{snapshot_id}")

    {data_path, meta_path} = Writer.snapshot_paths(snapshots_dir, snapshot_id)

    with {:ok, metadata} <- read_metadata(meta_path),
         {:ok, compressed_data} <- FileBackend.read_file(data_path),
         :ok <- validate_checksum(compressed_data, metadata.checksum),
         {:ok, uncompressed_data} <- decompress_data(compressed_data),
         {:ok, entries} <- Serializer.decode(uncompressed_data) do
      Logger.info("Snapshot #{snapshot_id} loaded with #{length(entries)} entries")
      {:ok, entries}
    else
      {:error, reason} = error ->
        Logger.error("Failed to read snapshot #{snapshot_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all available snapshots in a directory.

  Returns list of snapshot info sorted by LSN (newest first).

  ## Examples

      iex> SnapshotReader.list_snapshots("/data/snapshots")
      {:ok, [%{snapshot_id: "...", lsn: 1000, ...}, ...]}
  """
  @spec list_snapshots(String.t()) :: {:ok, [snapshot_info()]} | {:error, term()}
  def list_snapshots(snapshots_dir) do
    case FileBackend.list_files(snapshots_dir, "*.meta") do
      {:ok, meta_files} ->
        snapshots =
          meta_files
          |> Enum.map(&read_snapshot_info/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, info} -> info end)
          |> Enum.sort_by(& &1.lsn, :desc)

        {:ok, snapshots}

      {:error, :directory_not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets metadata for a specific snapshot.

  ## Examples

      iex> SnapshotReader.get_snapshot_metadata("/data/snapshots", snapshot_id)
      {:ok, %{lsn: 1000, entry_count: 500, ...}}
  """
  @spec get_snapshot_metadata(String.t(), snapshot_id()) ::
          {:ok, map()} | {:error, term()}
  def get_snapshot_metadata(snapshots_dir, snapshot_id) do
    {_data_path, meta_path} = Writer.snapshot_paths(snapshots_dir, snapshot_id)
    read_metadata(meta_path)
  end

  @doc """
  Validates a snapshot without loading all data.

  Checks that files exist and checksum is valid.

  ## Examples

      iex> SnapshotReader.validate_snapshot("/data/snapshots", snapshot_id)
      :ok
  """
  @spec validate_snapshot(String.t(), snapshot_id()) :: :ok | {:error, term()}
  def validate_snapshot(snapshots_dir, snapshot_id) do
    {data_path, meta_path} = Writer.snapshot_paths(snapshots_dir, snapshot_id)

    with {:ok, metadata} <- read_metadata(meta_path),
         {:ok, compressed_data} <- FileBackend.read_file(data_path) do
      validate_checksum(compressed_data, metadata.checksum)
    end
  end

  ## Private Functions

  @spec read_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_metadata(meta_path) do
    case FileBackend.read_file(meta_path) do
      {:ok, binary} ->
        Serializer.decode(binary)

      {:error, reason} ->
        {:error, {:metadata_read_failed, reason}}
    end
  end

  @spec read_snapshot_info(String.t()) :: {:ok, snapshot_info()} | {:error, term()}
  defp read_snapshot_info(meta_path) do
    case read_metadata(meta_path) do
      {:ok, metadata} ->
        info = %{
          snapshot_id: metadata.snapshot_id,
          lsn: metadata.lsn,
          entry_count: metadata.entry_count,
          created_at: metadata.created_at,
          compressed_size: metadata.compressed_size,
          uncompressed_size: metadata.uncompressed_size
        }

        {:ok, info}

      {:error, reason} ->
        Logger.warning("Failed to read snapshot info from #{meta_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec validate_checksum(binary(), non_neg_integer()) :: :ok | {:error, :corrupt_snapshot}
  defp validate_checksum(data, expected_checksum) do
    actual_checksum = Serializer.compute_checksum(data)

    if actual_checksum == expected_checksum do
      :ok
    else
      Logger.error(
        "Snapshot checksum mismatch: expected #{expected_checksum}, got #{actual_checksum}"
      )

      {:error, :corrupt_snapshot}
    end
  end

  @spec decompress_data(binary()) :: {:ok, binary()} | {:error, term()}
  defp decompress_data(compressed) do
    uncompressed = :zlib.gunzip(compressed)
    {:ok, uncompressed}
  rescue
    e ->
      {:error, {:decompression_failed, Exception.message(e)}}
  end
end
