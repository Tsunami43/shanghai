defmodule Cluster do
  @moduledoc """
  Public API for Shanghai Cluster functionality.

  This module provides a convenient interface for interacting with the cluster,
  including node membership, discovery, and event subscription.

  ## Architecture

  The cluster is built on three main components:

  - `Cluster.Membership`: Manages cluster topology and node membership
  - `Cluster.Heartbeat`: Monitors node liveness via heartbeat protocol
  - `Cluster.Gossip`: Propagates events and state using gossip protocol

  ## Usage

      # Get all nodes in the cluster
      nodes = Cluster.nodes()

      # Join a new node to the cluster
      node = Cluster.Entities.Node.new(node_id, "localhost", 4000)
      Cluster.join(node)

      # Subscribe to cluster events
      Cluster.subscribe()

      # Leave the cluster
      Cluster.leave(node_id)
  """

  alias Cluster.Entities.Node
  alias Cluster.Membership
  alias Cluster.State
  alias CoreDomain.Types.NodeId

  @doc """
  Returns all nodes in the cluster.
  """
  @spec nodes() :: [Node.t()]
  defdelegate nodes(), to: Membership, as: :all_nodes

  @doc "Returns the ids of all nodes, sorted. See `Cluster.State.node_ids/1`."
  @spec node_ids() :: [NodeId.t()]
  def node_ids, do: State.node_ids(cluster_state())

  @doc "Returns the `host:port` addresses of all nodes, sorted."
  @spec node_addresses() :: [String.t()]
  def node_addresses, do: State.node_addresses(cluster_state())

  @doc """
  Gets a specific node by ID.
  """
  @spec get_node(NodeId.t()) :: {:ok, Node.t()} | {:error, :not_found}
  defdelegate get_node(node_id), to: Membership

  @doc """
  Returns `true` when a node with `node_id` is a member of the cluster.
  """
  @spec member?(NodeId.t()) :: boolean()
  def member?(node_id), do: match?({:ok, _node}, get_node(node_id))

  @doc """
  Returns the nodes currently marked `:up`. Useful for routing reads and writes
  to live peers.
  """
  @spec up_nodes() :: [Node.t()]
  def up_nodes, do: Enum.filter(nodes(), &Node.up?/1)

  @doc "Returns the nodes currently marked `:down`."
  @spec down_nodes() :: [Node.t()]
  def down_nodes, do: Enum.filter(nodes(), &Node.down?/1)

  @doc "Returns the nodes currently marked `:suspect`."
  @spec suspect_nodes() :: [Node.t()]
  def suspect_nodes, do: Enum.filter(nodes(), &Node.suspect?/1)

  @doc """
  Returns the health ratio of the cluster: the fraction of nodes that are `:up`
  (0.0..1.0). See `Cluster.State.health_ratio/1`.
  """
  @spec health_ratio() :: float()
  def health_ratio, do: State.health_ratio(cluster_state())

  @doc """
  Requests a node to join the cluster.
  """
  @spec join(Node.t()) :: :ok | {:error, atom()}
  defdelegate join(node), to: Membership, as: :join_node

  @doc """
  Requests a node to leave the cluster.
  """
  @spec leave(NodeId.t(), atom()) :: :ok | {:error, atom()}
  defdelegate leave(node_id, reason \\ :graceful), to: Membership, as: :leave_node

  @doc """
  Gets the local node ID.
  """
  @spec local_node_id() :: NodeId.t()
  defdelegate local_node_id(), to: Membership

  @doc """
  Subscribes the calling process to cluster membership events.

  Events are sent as `{:cluster_event, event}` messages.
  """
  @spec subscribe() :: :ok
  defdelegate subscribe(), to: Membership

  @doc """
  Unsubscribes the calling process from cluster membership events.
  """
  @spec unsubscribe() :: :ok
  defdelegate unsubscribe(), to: Membership

  @doc """
  Returns the current cluster state.
  """
  @spec cluster_state() :: Cluster.State.t()
  defdelegate cluster_state(), to: Membership, as: :get_cluster

  @doc """
  Returns `true` when a strict majority of cluster nodes are `:up` (quorum is
  available for reads and writes).
  """
  @spec quorum_available?() :: boolean()
  def quorum_available?, do: State.quorum_available?(cluster_state())

  @doc """
  Returns `true` when the cluster is healthy: no `:down` and no `:suspect` nodes.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    cluster = cluster_state()
    State.status_count(cluster, :down) == 0 and State.status_count(cluster, :suspect) == 0
  end

  @doc """
  Returns a concise cluster status summary: the local node id, the total node
  count, per-status counts, and whether quorum is available.
  """
  @spec status() :: %{
          local_node_id: NodeId.t(),
          node_count: non_neg_integer(),
          up: non_neg_integer(),
          suspect: non_neg_integer(),
          down: non_neg_integer(),
          quorum_available: boolean(),
          quorum_size: non_neg_integer(),
          health_ratio: float()
        }
  def status do
    cluster = cluster_state()

    %{
      local_node_id: local_node_id(),
      node_count: State.node_count(cluster),
      up: State.status_count(cluster, :up),
      suspect: State.status_count(cluster, :suspect),
      down: State.status_count(cluster, :down),
      quorum_available: State.quorum_available?(cluster),
      quorum_size: State.quorum_size(cluster),
      health_ratio: State.health_ratio(cluster)
    }
  end
end
