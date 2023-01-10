defmodule Storage.Compaction.Compactor do
  @moduledoc """
  GenServer responsible for compacting storage segments.

  Periodically merges and compacts old segments to:
  - Reclaim space from deleted entries
  - Merge sorted runs in LSM tree
  - Optimize read performance
  """

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct compaction_in_progress: false,
              last_compaction: nil
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a compaction run.
  """
  @spec compact() :: :ok | {:error, :already_running}
  def compact do
    GenServer.call(__MODULE__, :compact)
  end

  @impl true
  def init(_opts) do
    # TODO: Load compaction strategy from config
    {:ok, %State{}}
  end

  @impl true
  def handle_call(:compact, _from, %State{compaction_in_progress: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    # TODO: Start compaction task
    # TODO: Select segments to compact
    # TODO: Merge and write new segments
    # TODO: Delete old segments after successful merge
    new_state = %{state | compaction_in_progress: true, last_compaction: DateTime.utc_now()}

    # Simulate async compaction
    send(self(), :compaction_complete)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:compaction_complete, state) do
    new_state = %{state | compaction_in_progress: false}
    {:noreply, new_state}
  end
end
