defmodule Storage.WAL.SegmentManager do
  @moduledoc """
  DynamicSupervisor for managing WAL segment processes.

  Manages the lifecycle of Segment GenServers:
  - Starting new segments
  - Stopping/sealing old segments
  - Looking up segments by ID
  - Listing all active segments

  Uses a Registry to map segment_id → pid for fast lookups.

  ## Examples

      iex> {:ok, segment_pid} = SegmentManager.start_segment(1, 0, "/data/segment_1.wal")
      iex> {:ok, ^segment_pid} = SegmentManager.get_segment(1)
      iex> :ok = SegmentManager.stop_segment(1)
  """

  use DynamicSupervisor

  alias Storage.WAL.Segment

  @registry Storage.WAL.SegmentRegistry

  ## Client API

  @doc """
  Starts the SegmentManager supervisor.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Starts a new segment process.

  ## Parameters

  - `segment_id` - Unique identifier for the segment
  - `start_lsn` - First LSN in this segment
  - `path` - File path for the segment
  - `opts` - Additional options (`:create` - whether to create new file)

  ## Examples

      iex> SegmentManager.start_segment(1, 100, "/data/seg1.wal")
      {:ok, pid}

      iex> SegmentManager.start_segment(1, 100, "/data/seg1.wal", create: false)
      {:ok, pid}
  """
  @spec start_segment(
          segment_id :: non_neg_integer(),
          start_lsn :: non_neg_integer(),
          path :: String.t(),
          opts :: keyword()
        ) :: DynamicSupervisor.on_start_child()
  def start_segment(segment_id, start_lsn, path, opts \\ []) do
    # Check if segment already running
    case get_segment(segment_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        create = Keyword.get(opts, :create, true)

        # Use via tuple for automatic registration
        name = {:via, Registry, {@registry, segment_id}}

        child_spec = %{
          id: {Segment, segment_id},
          start:
            {Segment, :start_link,
             [
               [
                 segment_id: segment_id,
                 start_lsn: start_lsn,
                 path: path,
                 create: create,
                 name: name
               ]
             ]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Gets a segment process by ID.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> SegmentManager.get_segment(1)
      {:ok, pid}

      iex> SegmentManager.get_segment(999)
      {:error, :not_found}
  """
  @spec get_segment(non_neg_integer()) :: {:ok, pid()} | {:error, :not_found}
  def get_segment(segment_id) do
    case Registry.lookup(@registry, segment_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops a segment process.

  ## Examples

      iex> SegmentManager.stop_segment(1)
      :ok
  """
  @spec stop_segment(non_neg_integer()) :: :ok
  def stop_segment(segment_id) do
    case get_segment(segment_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Lists all active segment IDs and PIDs.

  ## Examples

      iex> SegmentManager.list_segments()
      [{1, #PID<0.123.0>}, {2, #PID<0.124.0>}]
  """
  @spec list_segments() :: [{non_neg_integer(), pid()}]
  def list_segments do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Gets count of active segments.

  ## Examples

      iex> SegmentManager.count()
      3
  """
  @spec count() :: non_neg_integer()
  def count do
    length(DynamicSupervisor.which_children(__MODULE__))
  end

  ## Server Callbacks

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
