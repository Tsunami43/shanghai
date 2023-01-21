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

  alias Cluster.State
  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  @type state :: %{
          cluster: State.t(),
          local_node_id: NodeId.t(),
          subscribers: [pid()]
        }

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
      subscribers: []
    }

    Logger.info("Membership server started with node_id=#{local_node_id.value}")

    {:ok, state}
  end

  @impl true
  def handle_call({:join_node, node}, _from, %{cluster: cluster} = state) do
    case State.add_node(cluster, node) do
      {:ok, updated_cluster} ->
        {events, cluster_with_no_events} = State.take_events(updated_cluster)
        broadcast_events(events, state.subscribers)
        Logger.info("Node joined: #{node.id.value}")
        {:reply, :ok, %{state | cluster: cluster_with_no_events}}

      {:error, reason} = error ->
        Logger.warning("Failed to join node #{node.id.value}: #{reason}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:leave_node, node_id, reason}, _from, %{cluster: cluster} = state) do
    case State.remove_node(cluster, node_id, reason) do
      {:ok, updated_cluster} ->
        {events, cluster_with_no_events} = State.take_events(updated_cluster)
        broadcast_events(events, state.subscribers)
        Logger.info("Node left: #{node_id.value} (reason: #{reason})")
        {:reply, :ok, %{state | cluster: cluster_with_no_events}}

      {:error, reason} = error ->
        Logger.warning("Failed to remove node #{node_id.value}: #{reason}")
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
    Process.monitor(pid)
    updated_subscribers = [pid | state.subscribers]
    {:reply, :ok, %{state | subscribers: updated_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    updated_subscribers = List.delete(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: updated_subscribers}}
  end

  @impl true
  def handle_cast({:mark_suspect, node_id}, %{cluster: cluster} = state) do
    case State.mark_node_suspect(cluster, node_id) do
      {:ok, updated_cluster} ->
        Logger.info("Node marked suspect: #{node_id.value}")
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
        Logger.warning("Node marked down: #{node_id.value} (#{detection_method})")
        {:noreply, %{state | cluster: cluster_with_no_events}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:mark_up, node_id}, %{cluster: cluster} = state) do
    case State.mark_node_up(cluster, node_id) do
      {:ok, updated_cluster} ->
        Logger.info("Node marked up: #{node_id.value}")
        {:noreply, %{state | cluster: updated_cluster}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodeup, erlang_node, _info}, state) do
    Logger.info("Erlang node up: #{erlang_node}")
    # In future iterations, we'll handle automatic node discovery here
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, erlang_node, _info}, %{cluster: cluster} = state) do
    Logger.info("Erlang node down: #{erlang_node}")

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
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove crashed subscriber
    updated_subscribers = List.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: updated_subscribers}}
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

  defp broadcast_events(events, subscribers) do
    Enum.each(events, fn event ->
      Enum.each(subscribers, fn subscriber ->
        send(subscriber, {:cluster_event, event})
      end)
    end)
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
