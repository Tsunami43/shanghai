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

  @doc "Returns the ids of all peer nodes (members except the local node), sorted."
  @spec peer_ids() :: [NodeId.t()]
  def peer_ids, do: State.peer_ids(cluster_state())

  @doc "Returns the peer nodes (members except the local node)."
  @spec peers() :: [Node.t()]
  def peers do
    local = local_node_id()
    Enum.reject(nodes(), &(&1.id == local))
  end

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
  Returns the status of the node with `node_id` (`:up`, `:down`, or `:suspect`),
  or `nil` when it is not a member. See `Cluster.State.status_of/2`.
  """
  @spec node_status(NodeId.t()) :: Node.status() | nil
  def node_status(node_id), do: State.status_of(cluster_state(), node_id)

  @doc """
  Returns the `host:port` address of the node with `node_id`, or `nil` when it is
  not a member. See `Cluster.State.address_of/2`.
  """
  @spec node_address(NodeId.t()) :: String.t() | nil
  def node_address(node_id), do: State.address_of(cluster_state(), node_id)

  @doc """
  Returns the deterministic leader of the live cluster, the `:up` node with the
  lexicographically smallest id, or `nil` when none is up. Every node derives the
  same answer from the same membership view. See `Cluster.State.deterministic_leader/1`.
  """
  @spec deterministic_leader() :: NodeId.t() | nil
  def deterministic_leader, do: State.deterministic_leader(cluster_state())

  @doc """
  Returns the currently elected cluster leader from the live `Cluster.LeaderElection`
  process, or `nil` when none is up.
  """
  @spec leader() :: NodeId.t() | nil
  def leader, do: Cluster.LeaderElection.leader()

  @doc "Returns `true` when the local node is the currently elected cluster leader."
  @spec leader?() :: boolean()
  def leader?, do: Cluster.LeaderElection.leader?()

  @doc """
  Returns the nodes currently marked `:up`. Useful for routing reads and writes
  to live peers.
  """
  @spec up_nodes() :: [Node.t()]
  def up_nodes, do: Enum.filter(nodes(), &Node.up?/1)

  @doc "Returns the nodes currently marked `:down`."
  @spec down_nodes() :: [Node.t()]
  def down_nodes, do: Enum.filter(nodes(), &Node.down?/1)

  @doc """
  Returns the ids of the nodes currently marked `:up`, sorted by value. Useful
  for routing reads and writes to live peers.
  """
  @spec up_node_ids() :: [NodeId.t()]
  def up_node_ids, do: up_nodes() |> Enum.map(& &1.id) |> NodeId.sort()

  @doc "Returns the number of nodes currently marked `:up`."
  @spec up_count() :: non_neg_integer()
  def up_count, do: State.status_count(cluster_state(), :up)

  @doc """
  Returns a map of `namespace => up_node_count` across the live cluster. See
  `Cluster.State.up_by_namespace/1`.
  """
  @spec up_by_namespace() :: %{optional(String.t()) => non_neg_integer()}
  def up_by_namespace, do: State.up_by_namespace(cluster_state())

  @doc """
  Returns a map of `host => up_node_count` across the live cluster. See
  `Cluster.State.up_by_host/1`.
  """
  @spec up_by_host() :: %{optional(String.t()) => non_neg_integer()}
  def up_by_host, do: State.up_by_host(cluster_state())

  @doc """
  Returns the number of live-cluster nodes in the given id namespace. See
  `Cluster.State.count_in_namespace/2`.
  """
  @spec count_in_namespace(String.t()) :: non_neg_integer()
  def count_in_namespace(namespace) when is_binary(namespace) do
    State.count_in_namespace(cluster_state(), namespace)
  end

  @doc """
  Returns the largest number of live-cluster nodes sharing a single host, a
  co-location concentration metric. See `Cluster.State.max_nodes_per_host/1`.
  """
  @spec max_nodes_per_host() :: non_neg_integer()
  def max_nodes_per_host, do: State.max_nodes_per_host(cluster_state())

  @doc """
  Returns `true` when nodes are evenly spread across hosts in the live cluster.
  See `Cluster.State.balanced?/1`.
  """
  @spec balanced?() :: boolean()
  def balanced?, do: State.balanced?(cluster_state())

  @doc """
  Returns the nodes that are routable: `:up` with a heartbeat within
  `max_age_ms`, sorted by node id. See `Cluster.State.routable_nodes/2`.
  """
  @spec routable_nodes(non_neg_integer()) :: [Node.t()]
  def routable_nodes(max_age_ms) when is_integer(max_age_ms) do
    State.routable_nodes(cluster_state(), max_age_ms)
  end

  @doc "Returns the number of nodes currently marked `:down`."
  @spec down_count() :: non_neg_integer()
  def down_count, do: State.status_count(cluster_state(), :down)

  @doc "Returns the number of nodes currently marked `:suspect`."
  @spec suspect_count() :: non_neg_integer()
  def suspect_count, do: State.status_count(cluster_state(), :suspect)

  @doc "Returns the total number of nodes in the cluster."
  @spec node_count() :: non_neg_integer()
  def node_count, do: State.node_count(cluster_state())

  @doc """
  Returns `true` when the fraction of `:up` nodes is at least `threshold`
  (0.0..1.0). See `Cluster.State.meets_availability?/2`.
  """
  @spec meets_availability?(float()) :: boolean()
  def meets_availability?(threshold) when is_float(threshold) do
    State.meets_availability?(cluster_state(), threshold)
  end

  @doc "Returns the nodes currently marked `:suspect`."
  @spec suspect_nodes() :: [Node.t()]
  def suspect_nodes, do: Enum.filter(nodes(), &Node.suspect?/1)

  @doc """
  Returns the nodes that are not `:up` (`:down` or `:suspect`), those needing
  attention. Sorted by node id. See `Cluster.State.unavailable_nodes/1`.
  """
  @spec unavailable_nodes() :: [Node.t()]
  def unavailable_nodes, do: State.unavailable_nodes(cluster_state())

  @doc """
  Returns the health ratio of the cluster: the fraction of nodes that are `:up`
  (0.0..1.0). See `Cluster.State.health_ratio/1`.
  """
  @spec health_ratio() :: float()
  def health_ratio, do: State.health_ratio(cluster_state())

  @doc """
  Returns `true` when the local node is the only member of the cluster (a solo
  deployment). See `Cluster.State.single_node?/1`.
  """
  @spec single_node?() :: boolean()
  def single_node?, do: State.single_node?(cluster_state())

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
  Returns the local node's entity when it has joined the cluster, or `nil`. See
  `Cluster.State.local_node/1`.
  """
  @spec local_node() :: Node.t() | nil
  def local_node, do: State.local_node(cluster_state())

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
  Returns a serializable topology snapshot of the live cluster. See
  `Cluster.State.topology/1`.
  """
  @spec topology() :: map()
  def topology, do: State.topology(cluster_state())

  @doc """
  Returns `true` when a strict majority of cluster nodes are `:up` (quorum is
  available for reads and writes).
  """
  @spec quorum_available?() :: boolean()
  def quorum_available?, do: State.quorum_available?(cluster_state())

  @doc """
  Returns `true` when quorum is unavailable (fewer than a strict majority of
  nodes are `:up`). See `Cluster.State.quorum_lost?/1`.
  """
  @spec quorum_lost?() :: boolean()
  def quorum_lost?, do: State.quorum_lost?(cluster_state())

  @doc """
  Returns how many more `:up` nodes are needed to reach a majority quorum, or
  `0` when quorum is available. See `Cluster.State.quorum_shortfall/1`.
  """
  @spec quorum_shortfall() :: non_neg_integer()
  def quorum_shortfall, do: State.quorum_shortfall(cluster_state())

  @doc """
  Returns the number of node failures the cluster can tolerate while retaining
  quorum. See `Cluster.State.fault_tolerance/1`.
  """
  @spec fault_tolerance() :: non_neg_integer()
  def fault_tolerance, do: State.fault_tolerance(cluster_state())

  @doc """
  Returns `true` when the cluster is healthy: no `:down` and no `:suspect` nodes.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    cluster = cluster_state()
    State.status_count(cluster, :down) == 0 and State.status_count(cluster, :suspect) == 0
  end

  @doc """
  Returns `true` when the cluster is degraded: at least one `:down` or `:suspect`
  node. The inverse of `healthy?/0` for a non-empty cluster. See
  `Cluster.State.degraded?/1`.
  """
  @spec degraded?() :: boolean()
  def degraded?, do: State.degraded?(cluster_state())

  @doc """
  Returns `true` when every node in the live cluster is `:down`, a total
  outage. `false` for an empty cluster. See `Cluster.State.all_down?/1`.
  """
  @spec all_down?() :: boolean()
  def all_down?, do: State.all_down?(cluster_state())

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
          fault_tolerance: non_neg_integer(),
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
      fault_tolerance: State.fault_tolerance(cluster),
      health_ratio: State.health_ratio(cluster)
    }
  end
end
