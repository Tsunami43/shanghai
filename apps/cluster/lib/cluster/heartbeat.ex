defmodule Cluster.Heartbeat do
  @moduledoc """
  GenServer that manages heartbeat-based liveness detection.

  The Heartbeat process is responsible for:
  - Periodically sending heartbeats to all cluster nodes
  - Receiving and tracking heartbeats from other nodes
  - Detecting node failures based on missed heartbeats
  - Marking nodes as suspect or down when heartbeats are missed
  - Notifying the Membership process of status changes
  """

  use GenServer
  require Logger

  alias Cluster.Membership
  alias Cluster.ValueObjects.Heartbeat, as: HeartbeatVO
  alias CoreDomain.Types.NodeId

  @default_interval_ms 5_000
  @default_timeout_ms 15_000
  @default_suspect_timeout_ms 10_000

  @type heartbeat_state :: %{
          last_heartbeat: HeartbeatVO.t(),
          missed_count: non_neg_integer()
        }

  @type state :: %{
          local_node_id: NodeId.t(),
          sequence: non_neg_integer(),
          interval_ms: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          suspect_timeout_ms: non_neg_integer(),
          heartbeats: %{NodeId.t() => heartbeat_state()}
        }

  # Client API

  @doc """
  Starts the Heartbeat server.

  Options:
  - `:interval_ms` - Heartbeat interval in milliseconds (default: 5000)
  - `:timeout_ms` - Timeout before marking node as down (default: 15000)
  - `:suspect_timeout_ms` - Timeout before marking node as suspect (default: 10000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a heartbeat from a remote node.
  """
  @spec record_heartbeat(HeartbeatVO.t()) :: :ok
  def record_heartbeat(%HeartbeatVO{} = heartbeat) do
    GenServer.cast(__MODULE__, {:record_heartbeat, heartbeat})
  end

  @doc """
  Gets the last heartbeat received from a node.
  """
  @spec get_last_heartbeat(NodeId.t()) :: {:ok, HeartbeatVO.t()} | {:error, :not_found}
  def get_last_heartbeat(node_id) do
    GenServer.call(__MODULE__, {:get_last_heartbeat, node_id})
  end

  @doc """
  Gets all tracked heartbeats.
  """
  @spec all_heartbeats() :: %{NodeId.t() => heartbeat_state()}
  def all_heartbeats do
    GenServer.call(__MODULE__, :all_heartbeats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    local_node_id = Membership.local_node_id()

    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    suspect_timeout_ms = Keyword.get(opts, :suspect_timeout_ms, @default_suspect_timeout_ms)

    state = %{
      local_node_id: local_node_id,
      sequence: 0,
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      suspect_timeout_ms: suspect_timeout_ms,
      heartbeats: %{}
    }

    # Schedule first heartbeat
    schedule_heartbeat(interval_ms)
    # Schedule first check
    schedule_check(interval_ms)

    Logger.info("Heartbeat server started (interval=#{interval_ms}ms, timeout=#{timeout_ms}ms)")

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_heartbeat, heartbeat}, state) do
    node_id = heartbeat.node_id

    # Preserve missed_count if this is an existing node that was suspect
    # This allows the periodic check to detect recovery
    missed_count =
      case Map.fetch(state.heartbeats, node_id) do
        {:ok, %{missed_count: count}} when count > 0 -> count
        _ -> 0
      end

    heartbeat_state = %{
      last_heartbeat: heartbeat,
      missed_count: missed_count
    }

    updated_heartbeats = Map.put(state.heartbeats, node_id, heartbeat_state)

    # Emit telemetry metric for heartbeat RTT
    age_ms = HeartbeatVO.age_ms(heartbeat)
    Observability.Metrics.heartbeat_completed(
      age_ms,
      node_id.value,
      state.local_node_id.value
    )

    Logger.debug("Recorded heartbeat from #{node_id.value} (seq=#{heartbeat.sequence}, age=#{age_ms}ms)")

    {:noreply, %{state | heartbeats: updated_heartbeats}}
  end

  @impl true
  def handle_call({:get_last_heartbeat, node_id}, _from, state) do
    result =
      case Map.fetch(state.heartbeats, node_id) do
        {:ok, %{last_heartbeat: heartbeat}} -> {:ok, heartbeat}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:all_heartbeats, _from, state) do
    {:reply, state.heartbeats, state}
  end

  @impl true
  def handle_info(:send_heartbeat, state) do
    # Create and broadcast heartbeat to all nodes
    heartbeat = HeartbeatVO.new(state.local_node_id, state.sequence)

    # In a real implementation, this would send the heartbeat to all cluster nodes
    # For now, we'll just log it
    Logger.debug("Sending heartbeat (seq=#{state.sequence})")

    # Broadcast to other nodes via the gossip layer
    broadcast_heartbeat(heartbeat)

    # Schedule next heartbeat
    schedule_heartbeat(state.interval_ms)

    {:noreply, %{state | sequence: state.sequence + 1}}
  end

  @impl true
  def handle_info(:check_heartbeats, state) do
    # Check all tracked heartbeats for timeouts
    updated_heartbeats =
      Enum.reduce(state.heartbeats, state.heartbeats, fn {node_id, hb_state}, acc ->
        age_ms = HeartbeatVO.age_ms(hb_state.last_heartbeat)

        cond do
          # Node is down (exceeded timeout)
          age_ms >= state.timeout_ms ->
            Logger.warning("Node #{node_id.value} heartbeat timeout (#{age_ms}ms)")
            handle_node_timeout(node_id, :down)
            Map.update!(acc, node_id, fn s -> %{s | missed_count: s.missed_count + 1} end)

          # Node is suspect (exceeded suspect timeout)
          age_ms >= state.suspect_timeout_ms ->
            if hb_state.missed_count == 0 do
              Logger.info("Node #{node_id.value} marked suspect (#{age_ms}ms)")
              handle_node_timeout(node_id, :suspect)
            end

            Map.update!(acc, node_id, fn s -> %{s | missed_count: s.missed_count + 1} end)

          # Node is healthy
          true ->
            # Reset missed count and mark node as up if it was previously suspect
            if hb_state.missed_count > 0 do
              Logger.info("Node #{node_id.value} recovered, marking as up")
              handle_node_recovery(node_id)
              Map.update!(acc, node_id, fn s -> %{s | missed_count: 0} end)
            else
              acc
            end
        end
      end)

    # Schedule next check
    schedule_check(state.interval_ms)

    {:noreply, %{state | heartbeats: updated_heartbeats}}
  end

  # Private Functions

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :send_heartbeat, interval_ms)
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check_heartbeats, interval_ms)
  end

  defp broadcast_heartbeat(heartbeat) do
    # This will be implemented by the Gossip layer
    # For now, we'll use a simple message passing approach
    case Process.whereis(Cluster.Gossip) do
      nil ->
        :ok

      pid ->
        send(pid, {:broadcast_heartbeat, heartbeat})
    end
  end

  defp handle_node_timeout(node_id, status) do
    case status do
      :suspect ->
        # Mark node as suspect in the membership
        GenServer.cast(Cluster.Membership, {:mark_suspect, node_id})

      :down ->
        # Mark node as down in the membership
        GenServer.cast(Cluster.Membership, {:mark_down, node_id, :heartbeat_failure})
    end
  end

  defp handle_node_recovery(node_id) do
    # Mark node as up in the membership after recovering from suspect state
    GenServer.cast(Cluster.Membership, {:mark_up, node_id})
  end
end
