defmodule Cluster.State do
  @moduledoc """
  Cluster state aggregate - manages cluster membership and topology.

  The Cluster state aggregate is responsible for:
  - Tracking all known nodes in the cluster
  - Managing node join/leave protocols
  - Handling node liveness changes
  - Emitting domain events for membership changes
  """

  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeDetectedDown, NodeJoined, NodeLeft}
  alias CoreDomain.Types.NodeId

  @type t :: %__MODULE__{
          nodes: %{NodeId.t() => Node.t()},
          local_node_id: NodeId.t() | nil,
          events: [struct()]
        }

  defstruct nodes: %{},
            local_node_id: nil,
            events: []

  @doc """
  Creates a new Cluster aggregate.
  """
  @spec new(NodeId.t()) :: t()
  def new(local_node_id) do
    %__MODULE__{
      nodes: %{},
      local_node_id: local_node_id,
      events: []
    }
  end

  @doc """
  Adds a node to the cluster.

  Returns `{:ok, cluster, events}` if successful, or `{:error, reason}` if the node
  cannot be added (e.g., already exists).
  """
  @spec add_node(t(), Node.t()) :: {:ok, t()} | {:error, atom()}
  def add_node(%__MODULE__{nodes: nodes} = cluster, %Node{id: node_id} = node) do
    if Map.has_key?(nodes, node_id) do
      {:error, :node_already_exists}
    else
      event = NodeJoined.new(node)

      updated_cluster = %{
        cluster
        | nodes: Map.put(nodes, node_id, node),
          events: [event | cluster.events]
      }

      {:ok, updated_cluster}
    end
  end

  @doc """
  Removes a node from the cluster.

  Returns `{:ok, cluster}` if successful, or `{:error, reason}` if the node
  cannot be removed (e.g., doesn't exist).
  """
  @spec remove_node(t(), NodeId.t(), atom()) :: {:ok, t()} | {:error, atom()}
  def remove_node(%__MODULE__{nodes: nodes} = cluster, node_id, reason \\ :graceful) do
    if Map.has_key?(nodes, node_id) do
      event = NodeLeft.new(node_id, reason)

      updated_cluster = %{
        cluster
        | nodes: Map.delete(nodes, node_id),
          events: [event | cluster.events]
      }

      {:ok, updated_cluster}
    else
      {:error, :node_not_found}
    end
  end

  @doc """
  Marks a node as down.

  Returns `{:ok, cluster}` if successful, or `{:error, reason}` if the node
  cannot be marked down (e.g., doesn't exist).
  """
  @spec mark_node_down(t(), NodeId.t(), atom()) :: {:ok, t()} | {:error, atom()}
  def mark_node_down(
        %__MODULE__{nodes: nodes} = cluster,
        node_id,
        detection_method \\ :heartbeat_failure
      ) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} ->
        updated_node = Node.mark_down(node)
        event = NodeDetectedDown.new(node_id, detection_method)

        updated_cluster = %{
          cluster
          | nodes: Map.put(nodes, node_id, updated_node),
            events: [event | cluster.events]
        }

        {:ok, updated_cluster}

      :error ->
        {:error, :node_not_found}
    end
  end

  @doc """
  Marks a node as suspect.

  Returns `{:ok, cluster}` if successful, or `{:error, reason}` if the node
  cannot be marked suspect (e.g., doesn't exist).
  """
  @spec mark_node_suspect(t(), NodeId.t()) :: {:ok, t()} | {:error, atom()}
  def mark_node_suspect(%__MODULE__{nodes: nodes} = cluster, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} ->
        updated_node = Node.mark_suspect(node)
        updated_cluster = %{cluster | nodes: Map.put(nodes, node_id, updated_node)}
        {:ok, updated_cluster}

      :error ->
        {:error, :node_not_found}
    end
  end

  @doc """
  Marks a node as up and updates its last_seen_at timestamp.

  Returns `{:ok, cluster}` if successful, or `{:error, reason}` if the node
  cannot be marked up (e.g., doesn't exist).
  """
  @spec mark_node_up(t(), NodeId.t()) :: {:ok, t()} | {:error, atom()}
  def mark_node_up(%__MODULE__{nodes: nodes} = cluster, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} ->
        updated_node = Node.mark_up(node)
        updated_cluster = %{cluster | nodes: Map.put(nodes, node_id, updated_node)}
        {:ok, updated_cluster}

      :error ->
        {:error, :node_not_found}
    end
  end

  @doc """
  Gets a node by ID.
  """
  @spec get_node(t(), NodeId.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node(%__MODULE__{nodes: nodes}, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Finds a node by its `host:port` address. Returns `{:ok, node}` or
  `{:error, :not_found}`. When several nodes share an address, the first match
  (by sorted id) is returned.
  """
  @spec get_node_by_address(t(), String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node_by_address(%__MODULE__{} = cluster, address) when is_binary(address) do
    cluster
    |> all_nodes()
    |> Enum.sort_by(& &1.id.value)
    |> Enum.find(&(Node.address(&1) == address))
    |> case do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  @doc """
  Returns the ids of all nodes in the cluster, sorted by their string value.
  """
  @spec node_ids(t()) :: [NodeId.t()]
  def node_ids(%__MODULE__{nodes: nodes}) do
    nodes |> Map.keys() |> Enum.sort_by(& &1.value)
  end

  @doc """
  Returns the `host:port` addresses of all nodes, sorted.
  """
  @spec node_addresses(t()) :: [String.t()]
  def node_addresses(%__MODULE__{nodes: nodes}) do
    nodes |> Map.values() |> Enum.map(&Node.address/1) |> Enum.sort()
  end

  @doc """
  Returns the distinct hosts of all nodes, sorted. Useful for grouping nodes by
  physical machine.
  """
  @spec node_hosts(t()) :: [String.t()]
  def node_hosts(%__MODULE__{nodes: nodes}) do
    nodes |> Map.values() |> Enum.map(& &1.host) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Returns `true` when more than one node shares the same `host:port` address (a
  duplicate-registration smell).
  """
  @spec duplicate_addresses?(t()) :: boolean()
  def duplicate_addresses?(%__MODULE__{nodes: nodes}) do
    addresses = nodes |> Map.values() |> Enum.map(&Node.address/1)
    length(addresses) != length(Enum.uniq(addresses))
  end

  @doc """
  Returns the nodes located on `host`, sorted by node id. Empty when no node
  runs there.
  """
  @spec nodes_on_host(t(), String.t()) :: [Node.t()]
  def nodes_on_host(%__MODULE__{nodes: nodes}, host) do
    nodes
    |> Map.values()
    |> Enum.filter(&(&1.host == host))
    |> Enum.sort_by(& &1.id.value)
  end

  @doc "Returns the number of nodes located on `host`."
  @spec count_on_host(t(), String.t()) :: non_neg_integer()
  def count_on_host(%__MODULE__{nodes: nodes}, host) do
    Enum.count(Map.values(nodes), &(&1.host == host))
  end

  @doc """
  Returns a map of `host => node_count` across the cluster — a quick view of how
  nodes are distributed across physical machines.
  """
  @spec hosts_summary(t()) :: %{optional(String.t()) => non_neg_integer()}
  def hosts_summary(%__MODULE__{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.frequencies_by(& &1.host)
  end

  @doc """
  Returns all nodes in the cluster.
  """
  @spec all_nodes(t()) :: [Node.t()]
  def all_nodes(%__MODULE__{nodes: nodes}) do
    Map.values(nodes)
  end

  @doc """
  Returns the node whose last heartbeat is oldest (the most likely failed), or
  `nil` for an empty cluster. Never-seen nodes rank as stalest; ties break by
  node id for determinism.
  """
  @spec stalest_node(t()) :: Node.t() | nil
  def stalest_node(%__MODULE__{nodes: nodes}) when map_size(nodes) == 0, do: nil

  def stalest_node(%__MODULE__{} = cluster) do
    cluster
    |> all_nodes()
    |> Enum.min_by(&staleness_key/1)
  end

  defp staleness_key(%Node{last_seen_at: nil, id: id}), do: {0, 0, id.value}

  defp staleness_key(%Node{last_seen_at: ts, id: id}) do
    {1, DateTime.to_unix(ts, :millisecond), id.value}
  end

  @doc """
  Returns the node whose last heartbeat is most recent, or `nil` for an empty
  cluster. Never-seen nodes rank as least fresh; ties break by node id.
  """
  @spec freshest_node(t()) :: Node.t() | nil
  def freshest_node(%__MODULE__{nodes: nodes}) when map_size(nodes) == 0, do: nil

  def freshest_node(%__MODULE__{} = cluster) do
    cluster
    |> all_nodes()
    |> Enum.max_by(&staleness_key/1)
  end

  @doc """
  Returns all nodes with the specified status.
  """
  @spec nodes_with_status(t(), atom()) :: [Node.t()]
  def nodes_with_status(%__MODULE__{nodes: nodes}, status) do
    nodes
    |> Map.values()
    |> Enum.filter(&(&1.status == status))
  end

  @doc """
  Groups the cluster's nodes by status into `%{up: [...], suspect: [...],
  down: [...]}`. Each list is sorted by node id for deterministic output; a
  status with no members maps to `[]`.
  """
  @spec nodes_by_status(t()) :: %{
          up: [Node.t()],
          suspect: [Node.t()],
          down: [Node.t()]
        }
  def nodes_by_status(%__MODULE__{} = cluster) do
    %{
      up: sorted_with_status(cluster, :up),
      suspect: sorted_with_status(cluster, :suspect),
      down: sorted_with_status(cluster, :down)
    }
  end

  defp sorted_with_status(cluster, status) do
    cluster
    |> nodes_with_status(status)
    |> Enum.sort_by(& &1.id.value)
  end

  @doc """
  Returns `true` when the cluster has no member nodes.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{nodes: nodes}), do: map_size(nodes) == 0

  @doc """
  Returns the number of nodes in the cluster.
  """
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: nodes}) do
    map_size(nodes)
  end

  @doc """
  Returns the number of nodes with the specified status.
  """
  @spec status_count(t(), atom()) :: non_neg_integer()
  def status_count(%__MODULE__{} = cluster, status) do
    cluster
    |> nodes_with_status(status)
    |> length()
  end

  @doc """
  Returns the number of nodes required for a majority quorum (`⌊n/2⌋ + 1`), or
  `0` for an empty cluster.
  """
  @spec quorum_size(t()) :: non_neg_integer()
  def quorum_size(%__MODULE__{} = cluster) do
    case node_count(cluster) do
      0 -> 0
      total -> div(total, 2) + 1
    end
  end

  @doc """
  Returns the number of node failures the cluster can tolerate while still
  retaining a majority quorum (`n - quorum_size`). Returns `0` for an empty
  cluster.
  """
  @spec fault_tolerance(t()) :: non_neg_integer()
  def fault_tolerance(%__MODULE__{} = cluster) do
    node_count(cluster) - quorum_size(cluster)
  end

  @doc """
  Returns `true` when `count` constitutes a majority of the cluster's nodes
  (strictly more than half). Always `false` for an empty cluster.
  """
  @spec majority?(t(), non_neg_integer()) :: boolean()
  def majority?(%__MODULE__{} = cluster, count) when is_integer(count) do
    total = node_count(cluster)
    total > 0 and count > div(total, 2)
  end

  @doc """
  Returns a map of node counts per status: `%{up: n, suspect: n, down: n}`.
  """
  @spec status_summary(t()) :: %{
          up: non_neg_integer(),
          suspect: non_neg_integer(),
          down: non_neg_integer()
        }
  def status_summary(%__MODULE__{} = cluster) do
    %{
      up: status_count(cluster, :up),
      suspect: status_count(cluster, :suspect),
      down: status_count(cluster, :down)
    }
  end

  @doc """
  Returns true when a strict majority of the cluster's nodes are `:up` — the
  condition for serving quorum reads and writes. Always false for an empty
  cluster.
  """
  @spec quorum_available?(t()) :: boolean()
  def quorum_available?(%__MODULE__{} = cluster) do
    total = node_count(cluster)
    up = status_count(cluster, :up)
    total > 0 and up > div(total, 2)
  end

  @doc """
  Returns the health ratio: the fraction of nodes that are `:up` (0.0..1.0).
  Returns `0.0` for an empty cluster.
  """
  @spec health_ratio(t()) :: float()
  def health_ratio(%__MODULE__{} = cluster) do
    case node_count(cluster) do
      0 -> 0.0
      total -> status_count(cluster, :up) / total
    end
  end

  @doc """
  Returns a compact human-readable description of the cluster in the form
  `<node_count> nodes (up/suspect/down)`. Useful for logs.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = cluster) do
    summary = status_summary(cluster)
    "#{node_count(cluster)} nodes (#{summary.up}/#{summary.suspect}/#{summary.down})"
  end

  @doc """
  Returns a serializable topology snapshot of the cluster: the local node id (as
  a string, or `nil`), the total node count, per-status counts, and every node
  as a plain map (sorted by id).
  """
  @spec topology(t()) :: %{
          local_node_id: String.t() | nil,
          node_count: non_neg_integer(),
          status_summary: %{
            up: non_neg_integer(),
            suspect: non_neg_integer(),
            down: non_neg_integer()
          },
          nodes: [map()]
        }
  def topology(%__MODULE__{local_node_id: local} = cluster) do
    nodes =
      cluster
      |> all_nodes()
      |> Enum.sort_by(& &1.id.value)
      |> Enum.map(&Node.to_map/1)

    %{
      local_node_id: local && local.value,
      node_count: node_count(cluster),
      status_summary: status_summary(cluster),
      nodes: nodes
    }
  end

  @doc """
  Returns all pending events and clears the event list.
  """
  @spec take_events(t()) :: {[struct()], t()}
  def take_events(%__MODULE__{events: events} = cluster) do
    {Enum.reverse(events), %{cluster | events: []}}
  end

  @doc """
  Returns true if the specified node is in the cluster.
  """
  @spec has_node?(t(), NodeId.t()) :: boolean()
  def has_node?(%__MODULE__{nodes: nodes}, node_id) do
    Map.has_key?(nodes, node_id)
  end

  @doc """
  Returns the status of the node with `node_id` (`:up`, `:down`, or `:suspect`),
  or `nil` when the node is not a member.
  """
  @spec status_of(t(), NodeId.t()) :: Node.status() | nil
  def status_of(%__MODULE__{nodes: nodes}, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} -> node.status
      :error -> nil
    end
  end

  @doc """
  Returns the metadata of the node with `node_id`, or `nil` when the node is not
  a member.
  """
  @spec metadata_of(t(), NodeId.t()) :: map() | nil
  def metadata_of(%__MODULE__{nodes: nodes}, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} -> node.metadata
      :error -> nil
    end
  end

  @doc """
  Returns the local node's entity when it is a member of the cluster, or `nil`
  when the local id is unset or not yet joined.
  """
  @spec local_node(t()) :: Node.t() | nil
  def local_node(%__MODULE__{local_node_id: nil}), do: nil

  def local_node(%__MODULE__{local_node_id: id, nodes: nodes}) do
    Map.get(nodes, id)
  end

  @doc "Returns `true` when `node_id` is the cluster's local node id."
  @spec local?(t(), NodeId.t()) :: boolean()
  def local?(%__MODULE__{local_node_id: nil}, _node_id), do: false
  def local?(%__MODULE__{local_node_id: local}, node_id), do: local == node_id

  @doc """
  Returns the ids of all peer nodes (every member except the local node), sorted.
  """
  @spec peer_ids(t()) :: [NodeId.t()]
  def peer_ids(%__MODULE__{local_node_id: local} = cluster) do
    cluster
    |> node_ids()
    |> Enum.reject(&(&1 == local))
  end

  @doc """
  Updates node metadata.
  """
  @spec update_node_metadata(t(), NodeId.t(), map()) :: {:ok, t()} | {:error, atom()}
  def update_node_metadata(%__MODULE__{nodes: nodes} = cluster, node_id, metadata) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} ->
        updated_node = Node.update_metadata(node, metadata)
        updated_cluster = %{cluster | nodes: Map.put(nodes, node_id, updated_node)}
        {:ok, updated_cluster}

      :error ->
        {:error, :node_not_found}
    end
  end

  @doc """
  Touches a node to update its last_seen_at timestamp.
  """
  @spec touch_node(t(), NodeId.t()) :: {:ok, t()} | {:error, atom()}
  def touch_node(%__MODULE__{nodes: nodes} = cluster, node_id) do
    case Map.fetch(nodes, node_id) do
      {:ok, node} ->
        updated_node = Node.touch(node)
        updated_cluster = %{cluster | nodes: Map.put(nodes, node_id, updated_node)}
        {:ok, updated_cluster}

      :error ->
        {:error, :node_not_found}
    end
  end
end
