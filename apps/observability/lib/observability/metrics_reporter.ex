defmodule Observability.MetricsReporter do
  @moduledoc """
  Aggregates and reports telemetry metrics.

  This GenServer attaches to telemetry events and maintains
  rolling statistics for metrics queries.
  """

  use GenServer
  require Logger

  @type metric_stat :: %{
          count: non_neg_integer(),
          sum: number(),
          min: number(),
          max: number(),
          avg: float()
        }

  defmodule State do
    @moduledoc false
    defstruct wal_writes: %{},
              wal_syncs: %{},
              replication_lags: %{},
              heartbeats: %{},
              query_ops: %{},
              compactions: %{count: 0, last_duration_ms: 0, bytes_reclaimed: 0},
              last_membership_change: nil
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current WAL write statistics.
  """
  def get_wal_stats do
    GenServer.call(__MODULE__, :get_wal_stats)
  end

  @doc """
  Get current replication lag statistics by group.
  """
  def get_replication_stats do
    GenServer.call(__MODULE__, :get_replication_stats)
  end

  @doc """
  Get current heartbeat statistics.
  """
  def get_heartbeat_stats do
    GenServer.call(__MODULE__, :get_heartbeat_stats)
  end

  @doc """
  Get current query operation statistics, keyed by operation.
  """
  def get_query_stats do
    GenServer.call(__MODULE__, :get_query_stats)
  end

  @doc """
  Get compaction statistics (count, last duration, total bytes reclaimed).
  """
  def get_compaction_stats do
    GenServer.call(__MODULE__, :get_compaction_stats)
  end

  @doc """
  Get last cluster membership change.
  """
  def get_last_membership_change do
    GenServer.call(__MODULE__, :get_last_membership_change)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Attach to all telemetry events
    :telemetry.attach_many(
      "metrics-reporter",
      Observability.Metrics.event_names(),
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    Logger.info("MetricsReporter started and attached to telemetry events")

    {:ok, %State{}}
  end

  @impl true
  def handle_call(:get_wal_stats, _from, state) do
    stats = %{
      writes: state.wal_writes,
      syncs: state.wal_syncs
    }

    {:reply, stats, state}
  end

  def handle_call(:get_replication_stats, _from, state) do
    {:reply, state.replication_lags, state}
  end

  def handle_call(:get_heartbeat_stats, _from, state) do
    {:reply, state.heartbeats, state}
  end

  def handle_call(:get_query_stats, _from, state) do
    {:reply, state.query_ops, state}
  end

  def handle_call(:get_compaction_stats, _from, state) do
    {:reply, state.compactions, state}
  end

  def handle_call(:get_last_membership_change, _from, state) do
    {:reply, state.last_membership_change, state}
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    # A single malformed event must never take down the metrics reporter (and
    # with it the observability supervisor), so processing is defensive.
    updated_state =
      try do
        process_telemetry_event(event_name, measurements, metadata, state)
      rescue
        error ->
          Logger.warning(
            "MetricsReporter dropped #{inspect(event_name)}: #{Exception.message(error)}"
          )

          state
      end

    {:noreply, updated_state}
  end

  ## Telemetry Event Handler

  def handle_telemetry_event(event_name, measurements, metadata, _config) do
    # Send to GenServer for processing
    send(__MODULE__, {:telemetry_event, event_name, measurements, metadata})
  end

  ## Private Functions

  defp process_telemetry_event(
         [:shanghai, :storage, :wal, :write],
         measurements,
         _metadata,
         state
       ) do
    updated_writes = update_stat(state.wal_writes, measurements.duration)
    %{state | wal_writes: updated_writes}
  end

  defp process_telemetry_event([:shanghai, :storage, :wal, :sync], measurements, _metadata, state) do
    updated_syncs = update_stat(state.wal_syncs, measurements.duration)
    %{state | wal_syncs: updated_syncs}
  end

  defp process_telemetry_event(
         [:shanghai, :replication, :lag],
         measurements,
         %{group_id: group_id, follower_id: follower_id} = _metadata,
         state
       ) do
    key = "#{format_id(group_id)}/#{format_id(follower_id)}"
    current = Map.get(state.replication_lags, key, %{})
    updated = update_stat(current, measurements.offset_lag)

    updated_lags = Map.put(state.replication_lags, key, updated)
    %{state | replication_lags: updated_lags}
  end

  defp process_telemetry_event(
         [:shanghai, :cluster, :heartbeat],
         measurements,
         %{source_node: source, target_node: target} = _metadata,
         state
       ) do
    key = "#{format_id(source)}->#{format_id(target)}"
    current = Map.get(state.heartbeats, key, %{})
    updated = update_stat(current, measurements.rtt_ms)

    updated_heartbeats = Map.put(state.heartbeats, key, updated)
    %{state | heartbeats: updated_heartbeats}
  end

  defp process_telemetry_event(
         [:shanghai, :cluster, :membership_change],
         measurements,
         metadata,
         state
       ) do
    change_info = %{
      event_type: metadata.event_type,
      node_id: metadata.node_id,
      node_count: measurements.node_count,
      timestamp: DateTime.utc_now()
    }

    %{state | last_membership_change: change_info}
  end

  defp process_telemetry_event(
         [:shanghai, :query, :operation],
         measurements,
         %{operation: operation} = _metadata,
         state
       ) do
    current = Map.get(state.query_ops, operation, %{})
    updated = update_stat(current, measurements.duration_ms)
    %{state | query_ops: Map.put(state.query_ops, operation, updated)}
  end

  defp process_telemetry_event(
         [:shanghai, :storage, :compaction, :complete],
         measurements,
         _metadata,
         state
       ) do
    reclaimed =
      max(Map.get(measurements, :bytes_before, 0) - Map.get(measurements, :bytes_after, 0), 0)

    compactions = %{
      count: state.compactions.count + 1,
      last_duration_ms: Map.get(measurements, :duration_ms, 0),
      bytes_reclaimed: state.compactions.bytes_reclaimed + reclaimed
    }

    %{state | compactions: compactions}
  end

  defp process_telemetry_event(_event_name, _measurements, _metadata, state) do
    # Ignore other events
    state
  end

  # Renders an id to a string label. Handles NodeId-like structs (`%{value: v}`)
  # without depending on the core_domain app, plus plain strings/atoms.
  defp format_id(%{value: value}), do: to_string(value)
  defp format_id(id) when is_binary(id), do: id
  defp format_id(id), do: to_string(id)

  defp update_stat(nil, value), do: update_stat(%{}, value)

  defp update_stat(%{} = stat, value) when is_map(stat) do
    count = Map.get(stat, :count, 0) + 1
    sum = Map.get(stat, :sum, 0) + value
    min = min(Map.get(stat, :min, value), value)
    max = max(Map.get(stat, :max, value), value)
    avg = sum / count

    %{
      count: count,
      sum: sum,
      min: min,
      max: max,
      avg: avg
    }
  end
end
