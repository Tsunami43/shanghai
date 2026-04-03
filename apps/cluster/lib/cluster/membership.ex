defmodule Cluster.Membership do
  @moduledoc """
  GenServer that manages cluster membership state.

  The Membership process is responsible for:
  - Maintaining the current cluster state (Cluster aggregate)
  - Handling node join/leave requests
  - Coordinating with Erlang's distributed node system
  - Broadcasting membership events to subscribers
  - Tracking Erlang :nodeup/:nodedown events
  """

  use GenServer
  require Logger

  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeDetectedDown, NodeJoined, NodeLeft, NodeRecovered}
  alias Cluster.State
  alias CoreDomain.Types.NodeId

  @type state :: %{
          cluster: State.t(),
          local_node_id: NodeId.t(),
          subscribers: [pid()],
          monitors: %{pid() => reference()}
        }

  @anti_entropy_interval_ms 5_000

  # Client API

  @doc """
  Starts the Membership server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Requests a node to join the cluster.
  """
  @spec join_node(Node.t()) :: :ok | {:error, atom()}
  def join_node(%Node{} = node) do
    GenServer.call(__MODULE__, {:join_node, node})
  end

  @doc """
  Requests a node to leave the cluster.
  """
  @spec leave_node(NodeId.t(), atom()) :: :ok | {:error, atom()}
  def leave_node(node_id, reason \\ :graceful) do
    GenServer.call(__MODULE__, {:leave_node, node_id, reason})
  end

  @doc """
  Gets the current cluster state.
  """
  @spec get_cluster() :: Cluster.t()
  def get_cluster do
    GenServer.call(__MODULE__, :get_cluster)
  end

  @doc """
  Gets all nodes in the cluster.
  """
  @spec all_nodes() :: [Node.t()]
  def all_nodes do
    GenServer.call(__MODULE__, :all_nodes)
  end

  @doc """
  Gets a specific node by ID.
  """
  @spec get_node(NodeId.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node(node_id) do
    GenServer.call(__MODULE__, {:get_node, node_id})
  end

  @doc """
  Gets the local node ID.
  """
  @spec local_node_id() :: NodeId.t()
  def local_node_id do
    GenServer.call(__MODULE__, :local_node_id)
  end

  @doc """
  Subscribes to cluster membership events.

  The subscriber will receive messages in the format:
  - `{:cluster_event, event}`

  where event is one of: NodeJoined, NodeLeft, NodeDetectedDown
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribes from cluster membership events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc """
  Applies a cluster event received from a peer (via gossip) to the local
  membership view. Idempotent, and notifies local subscribers so leader election
  reacts — but it does not re-emit the event to gossip, so it cannot loop.
  """
  @spec apply_remote_event(struct()) :: :ok
  def apply_remote_event(event) do
    GenServer.cast(__MODULE__, {:apply_remote_event, event})
  end

  @doc """
  Merges a peer's node list into the local membership view (anti-entropy). Nodes
  not already known are added; existing nodes are left untouched. Idempotent and
  does not re-gossip, so it converges without looping.
  """
  @spec merge_membership([Node.t()]) :: :ok
  def merge_membership(nodes) when is_list(nodes) do
    GenServer.cast(__MODULE__, {:merge_membership, nodes})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Subscribe to Erlang node events
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Generate or get the local node ID
    local_node_id = get_or_create_local_node_id(opts)

    cluster = State.new(local_node_id)

    state = %{
      cluster: cluster,
      local_node_id: local_node_id,
      subscribers: [],
      monitors: %{}
    }

    Logger.info("Membership server started with node_id=#{local_node_id.value}")

    # Periodic anti-entropy: push our membership to every connected node so all
    # nodes converge on the union view regardless of start-up ordering or a
    # dropped message. Robust and simple — no request/response handshake needed.
    schedule_anti_entropy()

    {:ok, state}
  end

  @impl true
  def handle_call({:join_node, node}, _from, %{cluster: cluster} = state) do
    case State.add_node(cluster, node) do
      {:ok, updated_cluster} ->
        {events, cluster_with_no_events} = State.take_events(updated_cluster)
        broadcast_events(events, state.subscribers)

        # Emit telemetry metric for membership change
        node_count = State.node_count(cluster_with_no_events)

        Observability.Metrics.cluster_membership_changed(
          node_count,
          :node_joined,
          node.id.value
        )

        Observability.Logger.info("Node joined cluster",
          node_id: node.id.value,
          node_count: node_count
        )

        {:reply, :ok, %{state | cluster: cluster_with_no_events}}

      {:error, reason} = error ->
        Observability.Logger.warning("Failed to join node",
          node_id: node.id.value,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:leave_node, node_id, reason}, _from, %{cluster: cluster} = state) do
    case State.remove_node(cluster, node_id, reason) do
      {:ok, updated_cluster} ->
        {events, cluster_with_no_events} = State.take_events(updated_cluster)
        broadcast_events(events, state.subscribers)

        # Emit telemetry metric for membership change
        node_count = State.node_count(cluster_with_no_events)

        Observability.Metrics.cluster_membership_changed(
          node_count,
          :node_left,
          node_id.value
        )

        Observability.Logger.info("Node left cluster",
          node_id: node_id.value,
          reason: reason,
          node_count: node_count
        )

        {:reply, :ok, %{state | cluster: cluster_with_no_events}}

      {:error, reason} = error ->
        Observability.Logger.warning("Failed to remove node",
          node_id: node_id.value,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_cluster, _from, state) do
    {:reply, state.cluster, state}
  end

  @impl true
  def handle_call(:all_nodes, _from, %{cluster: cluster} = state) do
    nodes = State.all_nodes(cluster)
    {:reply, nodes, state}
  end

  @impl true
  def handle_call({:get_node, node_id}, _from, %{cluster: cluster} = state) do
    result = State.get_node(cluster, node_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:local_node_id, _from, state) do
    {:reply, state.local_node_id, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Monitor subscriber to detect crashes
    ref = Process.monitor(pid)
    updated_subscribers = [pid | state.subscribers]
    updated_monitors = Map.put(state.monitors, pid, ref)

    {:reply, :ok, %{state | subscribers: updated_subscribers, monitors: updated_monitors}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    # Remove monitor
    case Map.get(state.monitors, pid) do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end

    updated_subscribers = List.delete(state.subscribers, pid)
    updated_monitors = Map.delete(state.monitors, pid)

    {:reply, :ok, %{state | subscribers: updated_subscribers, monitors: updated_monitors}}
  end

  @impl true
  def handle_cast({:mark_suspect, node_id}, %{cluster: cluster} = state) do
    case State.mark_node_suspect(cluster, node_id) do
      {:ok, updated_cluster} ->
        Observability.Logger.info("Node marked suspect",
          node_id: node_id.value
        )

        {:noreply, %{state | cluster: updated_cluster}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:mark_down, node_id, detection_method}, %{cluster: cluster} = state) do
    case State.mark_node_down(cluster, node_id, detection_method) do
      {:ok, updated_cluster} ->
        {events, cluster_with_no_events} = State.take_events(updated_cluster)
        broadcast_events(events, state.subscribers)

        # Only emit telemetry/log on an actual transition — mark_node_down is a
        # no-op (no events) when the node is already down, and a periodic detector
        # must not spam a membership change every check.
        if events != [] do
          Observability.Metrics.cluster_membership_changed(
            State.node_count(cluster_with_no_events),
            :node_down,
            node_id.value
          )

          Observability.Logger.warning("Node marked down",
            node_id: node_id.value,
            detection_method: detection_method
          )
        end

        {:noreply, %{state | cluster: cluster_with_no_events}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:merge_membership, nodes}, %{cluster: cluster} = state) do
    {updated_cluster, added_events} =
      Enum.reduce(nodes, {cluster, []}, fn node, {acc_cluster, acc_events} ->
        case State.add_node(acc_cluster, node) do
          {:ok, updated} ->
            {events, without_events} = State.take_events(updated)
            {without_events, acc_events ++ events}

          {:error, :node_already_exists} ->
            {acc_cluster, acc_events}
        end
      end)

    # Notify local subscribers of newly learned nodes; do not re-gossip (the sync
    # message propagates through the gossip layer itself).
    notify_local(added_events, state.subscribers)

    {:noreply, %{state | cluster: updated_cluster}}
  end

  @impl true
  def handle_cast({:apply_remote_event, event}, %{cluster: cluster} = state) do
    case apply_remote(cluster, event) do
      {:ok, updated_cluster} ->
        {events, cluster_without_events} = State.take_events(updated_cluster)
        # Notify local subscribers (e.g. leader election) but do NOT push back to
        # gossip — the gossip layer re-propagates the original message itself, and
        # re-emitting here would create a loop.
        notify_local(events, state.subscribers)
        {:noreply, %{state | cluster: cluster_without_events}}

      :ignore ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:mark_up, node_id}, %{cluster: cluster} = state) do
    case State.mark_node_up(cluster, node_id) do
      {:ok, updated_cluster} ->
        Observability.Logger.info("Node marked up",
          node_id: node_id.value
        )

        {:noreply, %{state | cluster: updated_cluster}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodeup, erlang_node, _info}, %{cluster: cluster} = state) do
    Observability.Logger.info("Erlang node up",
      erlang_node: erlang_node
    )

    # A known member's distribution connection came back: mark it up again so the
    # membership view reflects reality and subscribers (e.g. leader election) can
    # react. Unknown Erlang nodes are ignored until they explicitly join.
    updated_state =
      case find_node_by_erlang_name(cluster, erlang_node) do
        nil ->
          state

        node_id ->
          recover_node(state, cluster, node_id)
      end

    # Push our membership straight to the peer that just connected for a fast
    # initial exchange; the periodic anti-entropy sweep converges it either way.
    push_membership_to(erlang_node, updated_state.cluster)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:anti_entropy, %{cluster: cluster} = state) do
    Enum.each(:erlang.nodes(:visible), fn erlang_node ->
      push_membership_to(erlang_node, cluster)
    end)

    schedule_anti_entropy()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, erlang_node, _info}, %{cluster: cluster} = state) do
    Observability.Logger.warning("Erlang node down",
      erlang_node: erlang_node
    )

    # Find the node by Erlang node name and mark it down
    node_id = find_node_by_erlang_name(cluster, erlang_node)

    updated_state =
      case node_id do
        nil ->
          state

        node_id ->
          case State.mark_node_down(cluster, node_id, :network_partition) do
            {:ok, updated_cluster} ->
              {events, cluster_with_no_events} = State.take_events(updated_cluster)
              broadcast_events(events, state.subscribers)
              %{state | cluster: cluster_with_no_events}

            {:error, _reason} ->
              state
          end
      end

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Remove crashed subscriber
    case Map.get(state.monitors, pid) do
      ^ref ->
        Observability.Logger.debug("Subscriber process down",
          pid: inspect(pid),
          reason: reason
        )

        updated_subscribers = List.delete(state.subscribers, pid)
        updated_monitors = Map.delete(state.monitors, pid)
        {:noreply, %{state | subscribers: updated_subscribers, monitors: updated_monitors}}

      _ ->
        {:noreply, state}
    end
  end

  # Private Functions

  defp get_or_create_local_node_id(opts) do
    case Keyword.get(opts, :node_id) do
      nil ->
        # Generate a node ID based on the Erlang node name
        node_name = node() |> Atom.to_string()
        NodeId.new(node_name)

      node_id when is_binary(node_id) ->
        NodeId.new(node_id)

      %NodeId{} = node_id ->
        node_id
    end
  end

  # Notifies local subscribers of events. Used for locally-originated changes
  # (which also gossip, see below) and for remote-applied changes (which must
  # not re-gossip).
  defp notify_local(events, subscribers) do
    Enum.each(events, fn event ->
      Enum.each(subscribers, fn subscriber ->
        send(subscriber, {:cluster_event, event})
      end)
    end)
  end

  # Notifies local subscribers AND propagates the events to peers via gossip.
  # Used only for locally-originated membership changes.
  defp broadcast_events(events, subscribers) do
    notify_local(events, subscribers)
    Enum.each(events, &gossip_event/1)
  end

  defp gossip_event(event) do
    if Process.whereis(Cluster.Gossip) do
      Cluster.Gossip.broadcast({:cluster_event, event})
    end

    :ok
  end

  # Delivers our current membership straight to a specific Erlang node (the one
  # that just connected), bypassing gossip's member-based targeting. Best-effort
  # and non-blocking, so an unreachable node cannot stall us.
  # Pushes our current membership straight to a specific Erlang node, bypassing
  # gossip's member-based targeting (a not-yet-member peer would not be a target).
  # Best-effort and non-blocking.
  defp push_membership_to(erlang_node, cluster) do
    payload = %{nodes: State.all_nodes(cluster)}

    :rpc.cast(erlang_node, Cluster.Gossip, :receive_gossip, [
      node(),
      [{:membership_sync, payload}]
    ])

    :ok
  end

  defp schedule_anti_entropy do
    Process.send_after(self(), :anti_entropy, @anti_entropy_interval_ms)
  end

  # Applies a received event to the cluster state, returning `{:ok, cluster}` on a
  # real change or `:ignore` when it is a duplicate/unknown. Idempotent.
  defp apply_remote(cluster, %NodeJoined{node: %Node{} = node}) do
    case State.add_node(cluster, node) do
      {:ok, updated} -> {:ok, updated}
      {:error, :node_already_exists} -> :ignore
    end
  end

  defp apply_remote(cluster, %NodeLeft{node_id: node_id}) do
    case State.remove_node(cluster, node_id, :graceful) do
      {:ok, updated} -> {:ok, updated}
      {:error, :node_not_found} -> :ignore
    end
  end

  defp apply_remote(cluster, %NodeDetectedDown{node_id: node_id, detection_method: method}) do
    normalize_apply(State.mark_node_down(cluster, node_id, method))
  end

  defp apply_remote(cluster, %NodeRecovered{node_id: node_id}) do
    normalize_apply(State.mark_node_up(cluster, node_id))
  end

  defp apply_remote(_cluster, _event), do: :ignore

  defp normalize_apply({:ok, updated}), do: {:ok, updated}
  defp normalize_apply({:error, _reason}), do: :ignore

  # Marks a known node up on connection recovery. No-op (returns state unchanged)
  # when the node is already up, so a flapping connection does not spam events.
  defp recover_node(state, cluster, node_id) do
    already_up? =
      case State.get_node(cluster, node_id) do
        {:ok, node} -> Node.up?(node)
        {:error, _} -> false
      end

    if already_up? do
      state
    else
      case State.mark_node_up(cluster, node_id) do
        {:ok, updated_cluster} ->
          event = NodeRecovered.new(node_id, :connection_restored)
          broadcast_events([event], state.subscribers)
          %{state | cluster: updated_cluster}

        {:error, _reason} ->
          state
      end
    end
  end

  defp find_node_by_erlang_name(cluster, erlang_node) do
    cluster
    |> State.all_nodes()
    |> Enum.find_value(fn node ->
      if Node.erlang_node_name(node) == erlang_node do
        node.id
      end
    end)
  end
end
