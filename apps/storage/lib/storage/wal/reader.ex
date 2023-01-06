defmodule Storage.WAL.Reader do
  @moduledoc """
  GenServer responsible for reading entries from the Write-Ahead Log.

  Supports:
  - Random access by LSN
  - Sequential scanning from a given LSN
  - Tailing the log for replication
  """

  use GenServer
  alias CoreDomain.Types.LogSequenceNumber

  defmodule State do
    @moduledoc false
    defstruct segment_cache: %{},
              open_files: %{}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads a log entry at the given LSN.
  """
  @spec read(LogSequenceNumber.t()) :: {:ok, term()} | {:error, :not_found}
  def read(lsn) do
    GenServer.call(__MODULE__, {:read, lsn})
  end

  @doc """
  Reads log entries from start_lsn up to end_lsn (inclusive).
  """
  @spec read_range(LogSequenceNumber.t(), LogSequenceNumber.t()) :: {:ok, [term()]}
  def read_range(start_lsn, end_lsn) do
    GenServer.call(__MODULE__, {:read_range, start_lsn, end_lsn})
  end

  @impl true
  def init(_opts) do
    # TODO: Scan WAL directory, build segment index
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:read, _lsn}, _from, state) do
    # TODO: Find segment containing LSN, read entry
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:read_range, _start_lsn, _end_lsn}, _from, state) do
    # TODO: Scan segments, collect entries
    {:reply, {:ok, []}, state}
  end
end
