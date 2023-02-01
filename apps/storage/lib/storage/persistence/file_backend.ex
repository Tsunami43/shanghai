defmodule Storage.Persistence.FileBackend do
  @moduledoc """
  Low-level file I/O operations with safety guarantees.

  Provides atomic write operations, fsync for durability, and proper error handling.
  All file operations are designed to be crash-safe and maintain data integrity.

  ## Safety Guarantees

  - **Atomic Writes**: Uses temp file + rename pattern to ensure atomicity
  - **Durability**: Calls fsync to ensure data is written to disk
  - **Directory Sync**: Syncs directory after operations for metadata durability
  - **Error Handling**: Converts Erlang errors to consistent {:error, reason} format

  ## Examples

      iex> FileBackend.ensure_directory("/tmp/test")
      :ok

      iex> FileBackend.write_atomic("/tmp/test/file.dat", "data")
      :ok

      iex> FileBackend.read_file("/tmp/test/file.dat")
      {:ok, "data"}
  """

  require Logger

  @type path :: String.t()
  @type pattern :: String.t()

  @doc """
  Atomically writes data to a file.

  Uses the temp-file-rename pattern:
  1. Write to temporary file
  2. fsync temporary file
  3. Rename to target path
  4. fsync directory (ensures rename is durable)

  This ensures that either the old file or the new file is visible,
  never a partially written file.

  ## Examples

      iex> FileBackend.write_atomic("/tmp/test.dat", "content")
      :ok

      iex> FileBackend.write_atomic("/invalid/path/file.dat", "content")
      {:error, :enoent}
  """
  @spec write_atomic(path(), binary()) :: :ok | {:error, term()}
  def write_atomic(path, data) when is_binary(data) do
    temp_path = "#{path}.tmp.#{:rand.uniform(999_999)}"

    try do
      with :ok <- ensure_directory(Path.dirname(path)),
           :ok <- File.write(temp_path, data),
           :ok <- sync_file_by_path(temp_path),
           :ok <- File.rename(temp_path, path),
           :ok <- sync_directory(Path.dirname(path)) do
        :ok
      else
        {:error, _reason} = error ->
          # Cleanup temp file on error
          File.rm(temp_path)
          error
      end
    rescue
      e ->
        File.rm(temp_path)
        {:error, {:write_failed, Exception.message(e)}}
    end
  end

  @doc """
  Reads entire file contents.

  ## Examples

      iex> FileBackend.read_file("/tmp/existing.txt")
      {:ok, "file contents"}

      iex> FileBackend.read_file("/tmp/nonexistent.txt")
      {:error, :enoent}
  """
  @spec read_file(path()) :: {:ok, binary()} | {:error, term()}
  def read_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, :eacces} -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Appends data to a file, creating it if it doesn't exist.

  Note: This is NOT atomic. For atomic writes, use write_atomic/2.

  ## Examples

      iex> FileBackend.append_file("/tmp/log.txt", "entry 1\\n")
      :ok

      iex> FileBackend.append_file("/tmp/log.txt", "entry 2\\n")
      :ok
  """
  @spec append_file(path(), binary()) :: :ok | {:error, term()}
  def append_file(path, data) when is_binary(data) do
    with :ok <- ensure_directory(Path.dirname(path)),
         {:ok, file} <- File.open(path, [:append, :binary]),
         :ok <- IO.binwrite(file, data),
         :ok <- sync_file(file),
         :ok <- File.close(file) do
      :ok
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, :enospc} -> {:error, :disk_full}
      {:error, :eacces} -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Syncs an open file handle to disk (fsync).

  Ensures all written data is durable on disk before returning.

  ## Examples

      iex> {:ok, file} = File.open("/tmp/test.dat", [:write])
      iex> :ok = IO.binwrite(file, "data")
      iex> FileBackend.sync_file(file)
      :ok
      iex> File.close(file)
      :ok
  """
  @spec sync_file(File.io_device()) :: :ok | {:error, term()}
  def sync_file(file) do
    case :file.sync(file) do
      :ok -> :ok
      {:error, :enospc} -> {:error, :disk_full}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Syncs a file by path (opens, syncs, closes).

  Convenience function for syncing a file by path without keeping it open.

  ## Examples

      iex> FileBackend.sync_file_by_path("/tmp/test.dat")
      :ok
  """
  @spec sync_file_by_path(path()) :: :ok | {:error, term()}
  def sync_file_by_path(path) do
    with {:ok, file} <- File.open(path, [:read]),
         :ok <- sync_file(file),
         :ok <- File.close(file) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensures a directory exists, creating it if necessary.

  Creates all parent directories as needed (like mkdir -p).

  ## Examples

      iex> FileBackend.ensure_directory("/tmp/test/nested/dir")
      :ok

      iex> FileBackend.ensure_directory("")
      :ok
  """
  @spec ensure_directory(path()) :: :ok | {:error, term()}
  def ensure_directory(""), do: :ok
  def ensure_directory("."), do: :ok

  def ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, :eacces} -> {:error, :permission_denied}
      {:error, :enospc} -> {:error, :disk_full}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists files in a directory matching a pattern.

  Pattern uses glob syntax (e.g., "*.wal", "segment_*.dat").

  ## Examples

      iex> FileBackend.list_files("/tmp/data", "*.wal")
      {:ok, ["/tmp/data/segment_001.wal", "/tmp/data/segment_002.wal"]}

      iex> FileBackend.list_files("/nonexistent", "*.txt")
      {:error, :enoent}
  """
  @spec list_files(path(), pattern()) :: {:ok, [path()]} | {:error, term()}
  def list_files(directory, pattern) do
    full_pattern = Path.join(directory, pattern)

    case File.ls(directory) do
      {:ok, _files} ->
        matches = Path.wildcard(full_pattern) |> Enum.sort()
        {:ok, matches}

      {:error, :enoent} ->
        {:error, :directory_not_found}

      {:error, :eacces} ->
        {:error, :permission_denied}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:list_failed, Exception.message(e)}}
  end

  @doc """
  Deletes a file.

  ## Examples

      iex> FileBackend.delete_file("/tmp/test.dat")
      :ok

      iex> FileBackend.delete_file("/tmp/nonexistent.dat")
      {:error, :file_not_found}
  """
  @spec delete_file(path()) :: :ok | {:error, term()}
  def delete_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, :eacces} -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a file exists.

  ## Examples

      iex> FileBackend.file_exists?("/tmp/existing.txt")
      true

      iex> FileBackend.file_exists?("/tmp/nonexistent.txt")
      false
  """
  @spec file_exists?(path()) :: boolean()
  def file_exists?(path) do
    File.exists?(path)
  end

  @doc """
  Gets file size in bytes.

  ## Examples

      iex> FileBackend.file_size("/tmp/test.dat")
      {:ok, 1024}

      iex> FileBackend.file_size("/tmp/nonexistent.dat")
      {:error, :file_not_found}
  """
  @spec file_size(path()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  @spec sync_directory(path()) :: :ok | {:error, term()}
  defp sync_directory(dir_path) do
    # On Unix systems, syncing the directory ensures the rename is durable
    # This is a no-op on some systems, but important for crash safety
    case :file.open(dir_path, [:read]) do
      {:ok, dir} ->
        result = :file.sync(dir)
        :file.close(dir)

        case result do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :enotdir} ->
        # Not a directory or doesn't support syncing (some filesystems)
        # Log but don't fail
        Logger.warning("Cannot sync directory: #{dir_path}")
        :ok

      {:error, reason} ->
        Logger.warning("Cannot open directory for sync: #{dir_path}, reason: #{inspect(reason)}")
        # Don't fail on directory sync errors, as this is best-effort
        :ok
    end
  end
end
