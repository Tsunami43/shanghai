defmodule Storage.Snapshot.Manager do
  @moduledoc """
  GenServer responsible for managing storage snapshots.

  Handles:
  - Creating point-in-time snapshots
  - Listing available snapshots
  - Cleaning up old snapshots (retention policy)
  - Restoring from snapshots (future)

  ## Retention Policy

  By default, keeps the most recent N snapshots (configurable, default: 5).
  Older snapshots are automatically deleted during cleanup.

  ## Examples

      iex> {:ok, snapshot_id} = Manager.create_snapshot(1000)
      iex> {:ok, snapshots} = Manager.list_snapshots()
      iex> :ok = Manager.cleanup_old_snapshots()
  """

  use GenServer
  require Logger

  alias Storage.Snapshot.{Writer, Reader}
  alias Storage.Persistence.FileBackend

  @default_retention_count 5

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            snapshots_dir: String.t(),
            retention_count: non_neg_integer(),
            reader_module: module()
          }

    defstruct [
      :snapshots_dir,
      :retention_count,
      :reader_module
    ]
  end

  ## Client API

  @doc """
  Starts the Snapshot.Manager GenServer.

  ## Options

  - `:snapshots_dir` - Directory to store snapshots (required)
  - `:retention_count` - Number of snapshots to keep (default: 5)
  - `:reader_module` - Module to use for reading WAL (default: Storage.WAL.Reader)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a snapshot up to the given LSN.

  ## Examples

      iex> Manager.create_snapshot(1000)
      {:ok, "snapshot_20260111_120000_lsn_0000000000001000"}
  """
  @spec create_snapshot(non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def create_snapshot(lsn) when is_integer(lsn) do
    GenServer.call(__MODULE__, {:create_snapshot, lsn}, :infinity)
  end

  @doc """
  Lists all available snapshots.

  Returns list sorted by LSN (newest first).

  ## Examples

      iex> Manager.list_snapshots()
      {:ok, [%{snapshot_id: "...", lsn: 1000, ...}]}
  """
  @spec list_snapshots() :: {:ok, [map()]} | {:error, term()}
  def list_snapshots do
    GenServer.call(__MODULE__, :list_snapshots)
  end

  @doc """
  Cleans up old snapshots according to retention policy.

  Keeps the most recent N snapshots, deletes the rest.

  ## Examples

      iex> Manager.cleanup_old_snapshots()
      {:ok, 3}  # Deleted 3 old snapshots
  """
  @spec cleanup_old_snapshots() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_old_snapshots do
    GenServer.call(__MODULE__, :cleanup_old_snapshots)
  end

  @doc """
  Gets information about a specific snapshot.

  ## Examples

      iex> Manager.get_snapshot_info(snapshot_id)
      {:ok, %{lsn: 1000, entry_count: 500, ...}}
  """
  @spec get_snapshot_info(String.t()) :: {:ok, map()} | {:error, term()}
  def get_snapshot_info(snapshot_id) do
    GenServer.call(__MODULE__, {:get_snapshot_info, snapshot_id})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    snapshots_dir = Keyword.fetch!(opts, :snapshots_dir)
    retention_count = Keyword.get(opts, :retention_count, @default_retention_count)
    reader_module = Keyword.get(opts, :reader_module, Storage.WAL.Reader)

    # Ensure directory exists
    :ok = FileBackend.ensure_directory(snapshots_dir)

    state = %State{
      snapshots_dir: snapshots_dir,
      retention_count: retention_count,
      reader_module: reader_module
    }

    Logger.info(
      "Snapshot Manager initialized, directory: #{snapshots_dir}, retention: #{retention_count}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:create_snapshot, lsn}, _from, state) do
    case Writer.create_snapshot(state.snapshots_dir, lsn, state.reader_module) do
      {:ok, snapshot_id} ->
        {:reply, {:ok, snapshot_id}, state}

      {:error, reason} = error ->
        Logger.error("Failed to create snapshot: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:list_snapshots, _from, state) do
    case Reader.list_snapshots(state.snapshots_dir) do
      {:ok, snapshots} ->
        {:reply, {:ok, snapshots}, state}

      {:error, reason} = error ->
        Logger.error("Failed to list snapshots: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:cleanup_old_snapshots, _from, state) do
    case cleanup_impl(state) do
      {:ok, deleted_count} ->
        {:reply, {:ok, deleted_count}, state}

      {:error, reason} = error ->
        Logger.error("Failed to cleanup snapshots: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:get_snapshot_info, snapshot_id}, _from, state) do
    case Reader.get_snapshot_metadata(state.snapshots_dir, snapshot_id) do
      {:ok, metadata} ->
        {:reply, {:ok, metadata}, state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  ## Private Functions

  @spec cleanup_impl(State.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp cleanup_impl(state) do
    case Reader.list_snapshots(state.snapshots_dir) do
      {:ok, snapshots} ->
        # Keep newest N snapshots, delete the rest
        snapshots_to_keep = Enum.take(snapshots, state.retention_count)
        snapshots_to_delete = Enum.drop(snapshots, state.retention_count)

        Logger.info(
          "Keeping #{length(snapshots_to_keep)} snapshots, deleting #{length(snapshots_to_delete)}"
        )

        deleted_count =
          Enum.reduce(snapshots_to_delete, 0, fn snapshot, acc ->
            case delete_snapshot_files(state.snapshots_dir, snapshot.snapshot_id) do
              :ok ->
                Logger.info("Deleted snapshot #{snapshot.snapshot_id}")
                acc + 1

              {:error, reason} ->
                Logger.warning(
                  "Failed to delete snapshot #{snapshot.snapshot_id}: #{inspect(reason)}"
                )

                acc
            end
          end)

        {:ok, deleted_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_snapshot_files(String.t(), String.t()) :: :ok | {:error, term()}
  defp delete_snapshot_files(snapshots_dir, snapshot_id) do
    {data_path, meta_path} = Writer.snapshot_paths(snapshots_dir, snapshot_id)

    with :ok <- delete_file_if_exists(data_path),
         :ok <- delete_file_if_exists(meta_path) do
      :ok
    end
  end

  @spec delete_file_if_exists(String.t()) :: :ok | {:error, term()}
  defp delete_file_if_exists(path) do
    case FileBackend.delete_file(path) do
      :ok -> :ok
      {:error, :file_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
