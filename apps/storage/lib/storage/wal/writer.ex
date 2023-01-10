defmodule Storage.WAL.Writer do
  @moduledoc """
  GenServer responsible for appending entries to the Write-Ahead Log.

  Ensures durability through fsync and manages log segments.
  All writes go through this process to maintain ordering and atomicity.
  """

  use GenServer
  alias CoreDomain.Types.LogSequenceNumber
  alias CoreDomain.Entities.LogEntry

  defmodule State do
    @moduledoc false
    defstruct current_lsn: nil,
              segment_path: nil,
              file_handle: nil
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends an entry to the WAL.
  Returns {:ok, lsn} on success.
  """
  @spec append(term()) :: {:ok, LogSequenceNumber.t()} | {:error, term()}
  def append(data) do
    GenServer.call(__MODULE__, {:append, data})
  end

  @impl true
  def init(_opts) do
    # TODO: Open WAL file, initialize LSN counter from disk
    initial_lsn = LogSequenceNumber.new(0)
    {:ok, %State{current_lsn: initial_lsn}}
  end

  @impl true
  def handle_call({:append, data}, _from, state) do
    # TODO: Serialize data, write to WAL file, fsync
    # TODO: Handle segment rotation when file gets too large
    new_lsn = LogSequenceNumber.increment(state.current_lsn)
    new_state = %{state | current_lsn: new_lsn}

    {:reply, {:ok, state.current_lsn}, new_state}
  end
end
