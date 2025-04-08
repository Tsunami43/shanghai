defmodule Replication.Monitor do
  @moduledoc """
  GenServer for monitoring replication health and lag.

  The Monitor tracks:
  - Follower offset lag behind leader
  - Replication latency
  - Unhealthy replicas
  - Replication throughput metrics
  """

  use GenServer
  require Logger

  alias Replication.ValueObjects.ReplicationOffset
  alias CoreDomain.Types.NodeId

  @type replica_metrics :: %{
          node_id: NodeId.t(),
          offset: ReplicationOffset.t(),
          lag: non_neg_integer(),
          last_update_at: integer(),
          status: :healthy | :lagging | :stale
        }

  @type group_metrics :: %{
          group_id: String.t(),
          leader_offset: ReplicationOffset.t(),
          replicas: %{NodeId.t() => replica_metrics()},
          last_check_at: integer()
        }

  @type state :: %{
          groups: %{String.t() => group_metrics()},
          lag_threshold: non_neg_integer(),
          stale_threshold_ms: non_neg_integer(),
          check_interval_ms: non_neg_integer()
        }

  @default_lag_threshold 1000
  @default_stale_threshold_ms 30_000
  @default_check_interval_ms 5_000

  # Client API

  @doc """
  Starts the Monitor process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a follower's offset for monitoring.
  """
  @spec record_follower_offset(String.t(), NodeId.t(), ReplicationOffset.t()) :: :ok
  def record_follower_offset(group_id, follower_id, offset) do
    GenServer.cast(__MODULE__, {:record_offset, group_id, follower_id, offset})
  end

  @doc """
  Records the leader's offset for a group.
  """
  @spec record_leader_offset(String.t(), ReplicationOffset.t()) :: :ok
  def record_leader_offset(group_id, offset) do
    GenServer.cast(__MODULE__, {:record_leader_offset, group_id, offset})
  end

  @doc """
  Gets replication metrics for a group.
  """
  @spec get_group_metrics(String.t()) :: {:ok, group_metrics()} | {:error, :not_found}
  def get_group_metrics(group_id) do
    GenServer.call(__MODULE__, {:get_metrics, group_id})
  end

  @doc """
  Gets all lagging replicas across all groups.
  """
  @spec get_lagging_replicas() :: [replica_metrics()]
  def get_lagging_replicas do
    GenServer.call(__MODULE__, :get_lagging_replicas)
  end

  @doc """
  Gets all stale replicas across all groups.
  """
  @spec get_stale_replicas() :: [replica_metrics()]
  def get_stale_replicas do
    GenServer.call(__MODULE__, :get_stale_replicas)
  end

  @doc """
  Gets all replication groups.
  """
  @spec all_groups() :: [group_metrics()]
  def all_groups do
    GenServer.call(__MODULE__, :all_groups)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    lag_threshold = Keyword.get(opts, :lag_threshold, @default_lag_threshold)
    stale_threshold_ms = Keyword.get(opts, :stale_threshold_ms, @default_stale_threshold_ms)
    check_interval_ms = Keyword.get(opts, :check_interval_ms, @default_check_interval_ms)

    state = %{
      groups: %{},
      lag_threshold: lag_threshold,
      stale_threshold_ms: stale_threshold_ms,
      check_interval_ms: check_interval_ms
    }

    # Schedule periodic health check
    schedule_check(check_interval_ms)

    Logger.info("Replication Monitor started")

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_offset, group_id, follower_id, offset}, state) do
    now = System.monotonic_time(:millisecond)

    group_metrics =
      Map.get(state.groups, group_id, %{
        group_id: group_id,
        leader_offset: ReplicationOffset.zero(),
        replicas: %{},
        last_check_at: now
      })

    lag = ReplicationOffset.lag(offset, group_metrics.leader_offset)
    status = calculate_status(lag, now, now, state)

    replica_metrics = %{
      node_id: follower_id,
      offset: offset,
      lag: lag,
      last_update_at: now,
      status: status
    }

    updated_replicas = Map.put(group_metrics.replicas, follower_id, replica_metrics)
    updated_group = %{group_metrics | replicas: updated_replicas, last_check_at: now}
    updated_groups = Map.put(state.groups, group_id, updated_group)

    {:noreply, %{state | groups: updated_groups}}
  end

  @impl true
  def handle_cast({:record_leader_offset, group_id, offset}, state) do
    now = System.monotonic_time(:millisecond)

    group_metrics =
      Map.get(state.groups, group_id, %{
        group_id: group_id,
        leader_offset: ReplicationOffset.zero(),
        replicas: %{},
        last_check_at: now
      })

    # Recalculate lag for all replicas
    updated_replicas =
      Map.new(group_metrics.replicas, fn {node_id, replica} ->
        lag = ReplicationOffset.lag(replica.offset, offset)
        status = calculate_status(lag, replica.last_update_at, now, state)
        {node_id, %{replica | lag: lag, status: status}}
      end)

    updated_group = %{
      group_metrics
      | leader_offset: offset,
        replicas: updated_replicas,
        last_check_at: now
    }

    updated_groups = Map.put(state.groups, group_id, updated_group)

    {:noreply, %{state | groups: updated_groups}}
  end

  @impl true
  def handle_call({:get_metrics, group_id}, _from, state) do
    case Map.get(state.groups, group_id) do
      nil -> {:reply, {:error, :not_found}, state}
      metrics -> {:reply, {:ok, metrics}, state}
    end
  end

  @impl true
  def handle_call(:get_lagging_replicas, _from, state) do
    lagging =
      state.groups
      |> Map.values()
      |> Enum.flat_map(fn group -> Map.values(group.replicas) end)
      |> Enum.filter(&(&1.status == :lagging))

    {:reply, lagging, state}
  end

  @impl true
  def handle_call(:get_stale_replicas, _from, state) do
    stale =
      state.groups
      |> Map.values()
      |> Enum.flat_map(fn group -> Map.values(group.replicas) end)
      |> Enum.filter(&(&1.status == :stale))

    {:reply, stale, state}
  end

  @impl true
  def handle_call(:all_groups, _from, state) do
    groups = Map.values(state.groups)
    {:reply, groups, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    updated_state = check_health(state)
    schedule_check(state.check_interval_ms)
    {:noreply, updated_state}
  end

  # Private Functions

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp check_health(state) do
    now = System.monotonic_time(:millisecond)

    updated_groups =
      Map.new(state.groups, fn {group_id, group} ->
        updated_replicas =
          Map.new(group.replicas, fn {node_id, replica} ->
            status = calculate_status(replica.lag, replica.last_update_at, now, state)

            if status != replica.status and status == :stale do
              Logger.warning(
                "Replica #{node_id.value} in group #{group_id} became stale (last update: #{now - replica.last_update_at}ms ago)"
              )
            end

            {node_id, %{replica | status: status}}
          end)

        {group_id, %{group | replicas: updated_replicas, last_check_at: now}}
      end)

    %{state | groups: updated_groups}
  end

  defp calculate_status(lag, last_update_at, now, state) do
    age_ms = now - last_update_at

    cond do
      age_ms > state.stale_threshold_ms -> :stale
      lag > state.lag_threshold -> :lagging
      true -> :healthy
    end
  end
end
