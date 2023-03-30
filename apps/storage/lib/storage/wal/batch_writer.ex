defmodule Storage.WAL.BatchWriter do
  @moduledoc """
  Batching layer for WAL writes to optimize fsync operations.

  ## Performance Optimization

  Instead of calling fsync after every single write, this module:
  1. Accumulates writes in a batch
  2. Performs batch fsync when either:
     - Batch size reaches threshold (default: 100 entries)
     - Batch time reaches threshold (default: 10ms)
     - Explicit flush requested

  This significantly improves throughput while maintaining durability
  guarantees.

  ## Durability Guarantees

  - All writes are flushed to disk before acknowledgment
  - Batching only affects when fsync happens, not if
  - Batch flush is atomic - all or nothing
  - Client calls block until their write is fsynced

  ## Usage

      # A `CoreDomain.Entities.LogEntry` is queued and batched automatically
      {:ok, offset} = BatchWriter.append(log_entry)

      # Force immediate flush
      :ok = BatchWriter.flush()
  """

  use GenServer
  require Logger

  alias CoreDomain.Entities.LogEntry
  alias Storage.WAL.Segment

  @default_batch_size 100
  @default_batch_timeout_ms 10

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            segment_pid: pid(),
            pending_writes: [map()],
            pending_count: non_neg_integer(),
            batch_size: non_neg_integer(),
            batch_timeout_ms: non_neg_integer(),
            flush_timer: reference() | nil
          }

    defstruct segment_pid: nil,
              pending_writes: [],
              pending_count: 0,
              batch_size: 100,
              batch_timeout_ms: 10,
              flush_timer: nil
  end

  ## Client API

  @doc """
  Starts the BatchWriter.

  Options:
  - `:segment_pid` - PID of the underlying segment (required)
  - `:batch_size` - Max entries per batch (default: 100)
  - `:batch_timeout_ms` - Max time to wait before flush (default: 10ms)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends a `LogEntry` to the WAL with batching.

  The entry is queued and will be fsynced when the batch is flushed. This call
  blocks until the write is safely on disk. The value must be a
  `CoreDomain.Entities.LogEntry` — it is written through `Segment.append_entry/2`.
  """
  @spec append(LogEntry.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(entry) do
    GenServer.call(__MODULE__, {:append, entry}, :infinity)
  end

  @doc """
  Forces an immediate flush of pending writes.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    segment_pid = Keyword.fetch!(opts, :segment_pid)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    batch_timeout_ms = Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms)

    state = %State{
      segment_pid: segment_pid,
      pending_writes: [],
      batch_size: batch_size,
      batch_timeout_ms: batch_timeout_ms,
      flush_timer: nil
    }

    Logger.info("BatchWriter started (batch_size=#{batch_size}, timeout=#{batch_timeout_ms}ms)")

    {:ok, state}
  end

  @impl true
  def handle_call({:append, data}, from, state) do
    write_req = %{
      data: data,
      from: from
    }

    pending = [write_req | state.pending_writes]
    new_count = state.pending_count + 1
    new_state = %{state | pending_writes: pending, pending_count: new_count}

    # Start flush timer if this is the first write
    new_state =
      if state.pending_count == 0 do
        timer = Process.send_after(self(), :flush_timeout, state.batch_timeout_ms)
        %{new_state | flush_timer: timer}
      else
        new_state
      end

    # Check if we should flush immediately
    if new_count >= state.batch_size do
      flush_batch(new_state)
      {:noreply, reset_state(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    if state.pending_count > 0 do
      flush_batch(state)
    end

    {:reply, :ok, reset_state(state)}
  end

  @impl true
  def handle_info(:flush_timeout, state) do
    if state.pending_count > 0 do
      flush_batch(state)
    end

    {:noreply, reset_state(state)}
  end

  ## Private Functions

  defp flush_batch(state) do
    batch_start = System.monotonic_time(:millisecond)

    # Execute all writes without fsync
    results =
      state.pending_writes
      |> Enum.reverse()
      |> Enum.map(fn write_req ->
        case write_without_sync(state.segment_pid, write_req.data) do
          {:ok, offset} -> {:ok, offset, write_req.from}
          {:error, reason} -> {:error, reason, write_req.from}
        end
      end)

    # Single fsync for the entire batch, amortizing durability cost.
    sync_start = System.monotonic_time(:millisecond)
    sync_result = sync_segment(state.segment_pid)
    sync_duration = System.monotonic_time(:millisecond) - sync_start
    batch_duration = System.monotonic_time(:millisecond) - batch_start

    if sync_result == :ok do
      Observability.Metrics.wal_sync_completed(sync_duration, :batch)
    end

    Logger.debug(
      "Flushed batch of #{length(results)} writes in #{batch_duration}ms (sync: #{sync_duration}ms)"
    )

    # Reply to all waiting clients. A failed batch fsync means the writes are not
    # durable, so successful writes are reported as errors too.
    Enum.each(results, fn
      {:ok, offset, from} ->
        case sync_result do
          :ok -> GenServer.reply(from, {:ok, offset})
          {:error, reason} -> GenServer.reply(from, {:error, {:sync_failed, reason}})
        end

      {:error, reason, from} ->
        GenServer.reply(from, {:error, reason})
    end)
  end

  defp write_without_sync(segment_pid, entry) do
    Segment.append_entry_no_sync(segment_pid, entry)
  end

  defp sync_segment(segment_pid) do
    Segment.sync(segment_pid)
  end

  defp reset_state(state) do
    if state.flush_timer do
      Process.cancel_timer(state.flush_timer)
    end

    %{state | pending_writes: [], pending_count: 0, flush_timer: nil}
  end
end
