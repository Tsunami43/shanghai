defmodule Storage.Compaction.Scheduler do
  @moduledoc """
  GenServer that periodically triggers compaction.

  Runs on a configurable interval and delegates to the Compactor for actual work.

  ## Configuration

  - `:interval` - How often to trigger compaction in milliseconds (default: 1 hour)
  - `:compactor` - Compactor module to use (default: Storage.Compaction.Compactor)
  - `:enabled` - Whether scheduling is enabled (default: true)

  ## Examples

      iex> {:ok, _pid} = Scheduler.start_link(interval: 60_000)
      iex> Scheduler.trigger_compaction()
      :ok
  """

  use GenServer
  require Logger

  # 1 hour
  @default_interval 3_600_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            interval: non_neg_integer(),
            compactor: module(),
            enabled: boolean(),
            timer_ref: reference() | nil
          }

    defstruct [
      :interval,
      :compactor,
      :enabled,
      :timer_ref
    ]
  end

  ## Client API

  @doc """
  Starts the Scheduler GenServer.

  ## Options

  - `:interval` - Compaction interval in ms (default: 1 hour)
  - `:compactor` - Compactor module (default: Storage.Compaction.Compactor)
  - `:enabled` - Enable scheduling (default: true)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers compaction immediately.

  Does not reset the scheduled timer.

  ## Examples

      iex> Scheduler.trigger_compaction()
      :ok
  """
  @spec trigger_compaction() :: :ok
  def trigger_compaction do
    GenServer.cast(__MODULE__, :trigger_compaction)
  end

  @doc """
  Gets scheduler statistics.

  ## Examples

      iex> Scheduler.stats()
      {:ok, %{interval: 3600000, enabled: true}}
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    compactor = Keyword.get(opts, :compactor, Storage.Compaction.Compactor)
    enabled = Keyword.get(opts, :enabled, true)

    state = %State{
      interval: interval,
      compactor: compactor,
      enabled: enabled,
      timer_ref: nil
    }

    Logger.info("Compaction Scheduler initialized, interval: #{interval}ms, enabled: #{enabled}")

    # Schedule first compaction if enabled
    new_state = if enabled, do: schedule_next_compaction(state), else: state

    {:ok, new_state}
  end

  @impl true
  def handle_cast(:trigger_compaction, state) do
    run_compaction(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      interval: state.interval,
      enabled: state.enabled,
      compactor: state.compactor
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info(:trigger_compaction, state) do
    Logger.debug("Scheduled compaction triggered")

    run_compaction(state)

    # Schedule next compaction
    new_state = if state.enabled, do: schedule_next_compaction(state), else: state

    {:noreply, new_state}
  end

  ## Private Functions

  @spec schedule_next_compaction(State.t()) :: State.t()
  defp schedule_next_compaction(state) do
    # Cancel previous timer if exists
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    # Schedule next compaction
    timer_ref = Process.send_after(self(), :trigger_compaction, state.interval)

    %{state | timer_ref: timer_ref}
  end

  @spec run_compaction(State.t()) :: :ok | {:error, term()}
  defp run_compaction(state) do
    case state.compactor.compact() do
      :ok ->
        Logger.info("Scheduled compaction completed successfully")
        :ok

      {:error, reason} ->
        Logger.warning("Scheduled compaction failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Compaction crashed: #{inspect(e)}")
      {:error, {:compaction_crash, Exception.message(e)}}
  end
end
