defmodule Storage.Snapshot.Manager do
  @moduledoc """
  GenServer responsible for managing storage snapshots.

  Handles:
  - Creating point-in-time snapshots
  - Restoring from snapshots
  - Cleaning up old snapshots
  """

  use GenServer
  alias CoreDomain.Types.LogSequenceNumber

  defmodule State do
    @moduledoc false
    defstruct snapshots: [],
              snapshot_directory: nil
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a snapshot at the current LSN.
  """
  @spec create_snapshot(LogSequenceNumber.t()) :: {:ok, String.t()} | {:error, term()}
  def create_snapshot(lsn) do
    GenServer.call(__MODULE__, {:create_snapshot, lsn})
  end

  @doc """
  Lists all available snapshots.
  """
  @spec list_snapshots() :: {:ok, [map()]}
  def list_snapshots do
    GenServer.call(__MODULE__, :list_snapshots)
  end

  @impl true
  def init(_opts) do
    # TODO: Scan snapshot directory, load snapshot metadata
    {:ok, %State{snapshots: []}}
  end

  @impl true
  def handle_call({:create_snapshot, lsn}, _from, state) do
    # TODO: Serialize current state to disk
    # TODO: Record snapshot metadata
    snapshot_id = "snapshot_#{lsn.value}_#{:os.system_time(:second)}"
    {:reply, {:ok, snapshot_id}, state}
  end

  @impl true
  def handle_call(:list_snapshots, _from, state) do
    {:reply, {:ok, state.snapshots}, state}
  end
end
