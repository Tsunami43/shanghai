defmodule Replication do
  @moduledoc """
  Public API for Shanghai Replication functionality.

  Provides access to replication group information, monitoring,
  and metrics for all replicated shards.
  """

  alias CoreDomain.Types.NodeId
  alias Replication.{Follower, GroupCoordinator, GroupSupervisor, Leader, Monitor, Stream}

  @doc """
  Starts a replication group leader on this node: the `Stream` (which fans out to
  followers) and the `Leader` (which accepts writes), supervised under
  `Replication.GroupSupervisor`.

  Options are forwarded to `Leader` (e.g. `:node_id`, `:replica_count`) and, where
  relevant, to `Stream` (`:batch_size`, `:flush_interval_ms`).
  """
  @spec start_leader(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_leader(group_id, opts \\ []) when is_binary(group_id) do
    stream_opts = [group_id: group_id] ++ Keyword.take(opts, [:batch_size, :flush_interval_ms])

    with {:ok, _stream} <- start_group_child({Stream, stream_opts}) do
      start_group_child({Leader, [group_id: group_id] ++ opts})
    end
  end

  @doc """
  Starts a replication group follower on this node, supervised under
  `Replication.GroupSupervisor`. Options are forwarded to `Follower` (e.g.
  `:node_id`, `:leader_node_id`).
  """
  @spec start_follower(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_follower(group_id, opts \\ []) when is_binary(group_id) do
    start_group_child({Follower, [group_id: group_id] ++ opts})
  end

  @doc """
  Starts the correct replication role for `group_id` on this node from a shared
  group descriptor, so every node in the group can call this with the same
  arguments and self-assign its role deterministically.

  The leader is the member with the smallest node id — the same deterministic
  rule the cluster uses for leader election — unless `:leader_id` is given. On the
  leader node this starts the `Stream` and `Leader` and registers every other
  member as a follower target; on another member it starts a `Follower` that
  follows the leader. A node that is not a member starts nothing and returns
  `{:ok, :not_a_member}`.

  Options:
  - `:members` - list of `NodeId.t()` in the group (required, non-empty)
  - `:leader_id` - `NodeId.t()` of the group leader (default: smallest member id)
  - `:this_node` - `NodeId.t()` of the local node (default: derived from `node()`)
  - remaining options are forwarded to `Leader`/`Stream` on the leader node and to
    `Follower` on a follower node (e.g. `:replica_count`, `:batch_size`,
    `:on_apply`, `:persist_wal`). `:replica_count` defaults to the member count.
  """
  @spec start_group(String.t(), keyword()) ::
          {:ok, pid()} | {:ok, :not_a_member} | {:error, term()}
  def start_group(group_id, opts) when is_binary(group_id) do
    case Keyword.get(opts, :members, []) do
      [] ->
        {:error, :no_members}

      members ->
        this_node = Keyword.get(opts, :this_node) || local_node_id()
        leader_id = Keyword.get(opts, :leader_id) || NodeId.min_of(members)
        role_opts = Keyword.drop(opts, [:members, :leader_id, :this_node])

        start_group_role(group_id, members, leader_id, this_node, role_opts)
    end
  end

  defp start_group_role(group_id, members, leader_id, this_node, opts) do
    cond do
      not Enum.any?(members, &NodeId.equal?(&1, this_node)) ->
        {:ok, :not_a_member}

      NodeId.equal?(this_node, leader_id) ->
        start_group_leader_role(group_id, members, leader_id, opts)

      true ->
        follower_opts =
          opts |> Keyword.put(:node_id, this_node) |> Keyword.put(:leader_node_id, leader_id)

        start_follower(group_id, follower_opts)
    end
  end

  defp start_group_leader_role(group_id, members, leader_id, opts) do
    leader_opts =
      opts
      |> Keyword.put_new(:replica_count, length(members))
      |> Keyword.put(:node_id, leader_id)

    with {:ok, pid} <- start_leader(group_id, leader_opts) do
      # Register every other member as a follower target so the Stream fans out to
      # it; the follower process itself runs on that member's own node.
      members
      |> Enum.reject(&NodeId.equal?(&1, leader_id))
      |> Enum.each(fn follower_id -> Stream.add_follower(group_id, follower_id) end)

      {:ok, pid}
    end
  end

  defp local_node_id do
    node() |> Atom.to_string() |> NodeId.new()
  end

  @doc """
  Returns the replication groups configured via `config :replication, :groups`,
  each as a normalized keyword list ready to pass to `GroupCoordinator.start_link/1`
  (its `:group_id` is filled in from the entry's `:id` or `:group_id`). Entries
  without a group id are dropped. Accepts entries given as keyword lists or maps.
  """
  @spec configured_groups() :: [keyword()]
  def configured_groups do
    :replication
    |> Application.get_env(:groups, [])
    |> Enum.map(&normalize_group_opts/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_group_opts(opts) when is_map(opts) do
    opts |> Map.to_list() |> normalize_group_opts()
  end

  defp normalize_group_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :group_id) || Keyword.get(opts, :id) do
      nil -> nil
      group_id -> opts |> Keyword.delete(:id) |> Keyword.put(:group_id, group_id)
    end
  end

  defp normalize_group_opts(_opts), do: nil

  @doc """
  Returns this node's role in every replication group it coordinates, as a map of
  `group_id => role` (`:leader`, `:follower` or `:none`). Only groups with a
  `GroupCoordinator` running on this node are included; groups started directly
  via `start_leader/2`/`start_follower/2` (no coordinator) are not listed.
  """
  @spec local_group_roles() :: %{optional(String.t()) => :leader | :follower | :none}
  def local_group_roles do
    Replication.Registry
    |> Registry.select([{{{:coordinator, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Map.new(fn group_id -> {group_id, GroupCoordinator.current_role(group_id)} end)
  end

  @doc """
  Stops every process for `group_id` on this node — the `Leader`, `Stream` and
  `Follower`, whichever are present — terminating them under
  `Replication.GroupSupervisor`. Returns `:ok`, and is safe to call when the group
  has no processes on this node. Used to tear a role down before switching to
  another (e.g. on a leader failover).
  """
  @spec stop_group(String.t()) :: :ok
  def stop_group(group_id) when is_binary(group_id) do
    for role <- [:leader, :follower, :stream],
        {pid, _value} <- Registry.lookup(Replication.Registry, {role, group_id}) do
      DynamicSupervisor.terminate_child(GroupSupervisor, pid)
    end

    :ok
  end

  defp start_group_child(child_spec) do
    case DynamicSupervisor.start_child(GroupSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Gets all replication groups with their current metrics.

  Returns a list of group metrics including leader offsets and follower status.
  """
  @spec all_groups() :: [map()]
  defdelegate all_groups(), to: Monitor

  @doc """
  Gets metrics for a specific replication group.
  """
  @spec get_group_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_group_metrics(group_id), to: Monitor

  @doc """
  Gets all lagging replicas across all groups.
  """
  @spec get_lagging_replicas() :: [map()]
  defdelegate get_lagging_replicas(), to: Monitor

  @doc """
  Gets all stale replicas across all groups.
  """
  @spec get_stale_replicas() :: [map()]
  defdelegate get_stale_replicas(), to: Monitor

  @doc """
  Returns a concise replication summary: the number of groups, the total number
  of tracked replicas, and how many replicas are lagging or stale.
  """
  @spec summary() :: %{
          groups: non_neg_integer(),
          replicas: non_neg_integer(),
          lagging: non_neg_integer(),
          stale: non_neg_integer(),
          healthy: boolean(),
          max_lag: non_neg_integer()
        }
  def summary do
    groups = all_groups()

    replica_count =
      Enum.reduce(groups, 0, fn group, acc ->
        acc + map_size(Map.get(group, :replicas, %{}))
      end)

    lagging = length(get_lagging_replicas())
    stale = length(get_stale_replicas())

    %{
      groups: length(groups),
      replicas: replica_count,
      lagging: lagging,
      stale: stale,
      healthy: lagging == 0 and stale == 0,
      max_lag: max_lag()
    }
  end

  @doc """
  Returns `true` when replication is healthy: no lagging and no stale replicas.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    get_lagging_replicas() == [] and get_stale_replicas() == []
  end

  @doc """
  Returns the total number of tracked replicas across all replication groups.
  """
  @spec replica_count() :: non_neg_integer()
  def replica_count do
    Enum.reduce(all_groups(), 0, fn group, acc ->
      acc + map_size(Map.get(group, :replicas, %{}))
    end)
  end

  @doc "Returns `true` when no replicas are tracked across any group."
  @spec no_replicas?() :: boolean()
  def no_replicas?, do: replica_count() == 0

  @doc "Returns the number of lagging replicas across all groups."
  @spec lagging_count() :: non_neg_integer()
  def lagging_count, do: length(get_lagging_replicas())

  @doc """
  Returns `true` when at least one replica is lagging behind its leader.
  """
  @spec any_lagging?() :: boolean()
  def any_lagging?, do: get_lagging_replicas() != []

  @doc "Returns the number of stale replicas across all groups."
  @spec stale_count() :: non_neg_integer()
  def stale_count, do: length(get_stale_replicas())

  @doc """
  Returns the number of replicas that are healthy (neither lagging nor stale)
  across all groups.
  """
  @spec healthy_replica_count() :: non_neg_integer()
  def healthy_replica_count do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.count(&(Map.get(&1, :status, :healthy) == :healthy))
  end

  @doc """
  Returns `true` when at least one replica is stale (hasn't reported recently).
  """
  @spec any_stale?() :: boolean()
  def any_stale?, do: get_stale_replicas() != []

  @doc """
  Returns `true` when any replica across all groups is lagging or stale.
  """
  @spec any_unhealthy?() :: boolean()
  def any_unhealthy?, do: lagging_count() > 0 or stale_count() > 0

  @doc """
  Returns the fraction of replicas that are lagging or stale (0.0..1.0), or
  `0.0` when there are no replicas. A quick unhealthy-replica ratio.
  """
  @spec unhealthy_ratio() :: float()
  def unhealthy_ratio do
    case replica_count() do
      0 -> 0.0
      total -> (lagging_count() + stale_count()) / total
    end
  end

  @doc """
  Returns `true` when there are no lagging or stale replicas *and* every group
  has at least one replica — a stricter check than `healthy?/0`, which is also
  true for a cluster with no replicas configured.
  """
  @spec fully_replicated?() :: boolean()
  def fully_replicated? do
    groups = all_groups()

    groups != [] and
      Enum.all?(groups, fn group -> map_size(Map.get(group, :replicas, %{})) > 0 end) and
      healthy?()
  end

  @doc """
  Returns the ids of all replication groups, sorted.
  """
  @spec group_ids() :: [String.t()]
  def group_ids do
    all_groups()
    |> Enum.map(& &1.group_id)
    |> Enum.sort()
  end

  @doc """
  Returns the ids of replication groups with no tracked replicas (a
  leader-only or misconfigured group), sorted.
  """
  @spec empty_group_ids() :: [String.t()]
  def empty_group_ids do
    all_groups()
    |> Enum.filter(fn group -> map_size(Map.get(group, :replicas, %{})) == 0 end)
    |> Enum.map(& &1.group_id)
    |> Enum.sort()
  end

  @doc "Returns `true` when no replication groups are being tracked."
  @spec no_groups?() :: boolean()
  def no_groups?, do: all_groups() == []

  @doc """
  Returns the average number of replicas per replication group, or `0.0` when
  there are no groups.
  """
  @spec avg_replicas_per_group() :: float()
  def avg_replicas_per_group do
    case group_count() do
      0 -> 0.0
      groups -> replica_count() / groups
    end
  end

  @doc """
  Returns the ids of replication groups that have at least one lagging or stale
  replica — the groups worth investigating. Sorted.
  """
  @spec unhealthy_group_ids() :: [String.t()]
  def unhealthy_group_ids do
    all_groups()
    |> Enum.filter(fn group ->
      group
      |> Map.get(:replicas, %{})
      |> Map.values()
      |> Enum.any?(fn replica -> Map.get(replica, :status, :healthy) != :healthy end)
    end)
    |> Enum.map(& &1.group_id)
    |> Enum.sort()
  end

  @doc """
  Returns the number of replication groups with at least one lagging or stale
  replica.
  """
  @spec unhealthy_group_count() :: non_neg_integer()
  def unhealthy_group_count, do: length(unhealthy_group_ids())

  @doc """
  Returns `true` when a replication group with `group_id` is being tracked.
  """
  @spec has_group?(String.t()) :: boolean()
  def has_group?(group_id) do
    match?({:ok, _metrics}, get_group_metrics(group_id))
  end

  @doc """
  Returns the number of replicas tracked in `group_id`, or `0` when the group is
  unknown.
  """
  @spec group_replica_count(String.t()) :: non_neg_integer()
  def group_replica_count(group_id) do
    case get_group_metrics(group_id) do
      {:ok, group} -> map_size(Map.get(group, :replicas, %{}))
      {:error, :not_found} -> 0
    end
  end

  @doc """
  Returns the follower ids tracked in `group_id`, sorted, or `[]` when the group
  is unknown.
  """
  @spec replica_ids(String.t()) :: [NodeId.t()]
  def replica_ids(group_id) do
    case get_group_metrics(group_id) do
      {:ok, group} ->
        group |> Map.get(:replicas, %{}) |> Map.keys() |> NodeId.sort()

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Returns a map of `group_id => replica_count` for every tracked replication
  group.
  """
  @spec group_sizes() :: %{optional(String.t()) => non_neg_integer()}
  def group_sizes do
    Map.new(all_groups(), fn group ->
      {group.group_id, map_size(Map.get(group, :replicas, %{}))}
    end)
  end

  @doc """
  Returns the id and replica count of the group with the most tracked replicas as
  `{group_id, count}`, or `nil` when no groups are tracked. Ties are broken by
  the group id order.
  """
  @spec largest_group() :: {String.t(), non_neg_integer()} | nil
  def largest_group, do: extreme_group(&Enum.max_by/2)

  @doc """
  Returns the id and replica count of the group with the fewest tracked replicas
  as `{group_id, count}`, or `nil` when no groups are tracked. Ties are broken by
  the group id order.
  """
  @spec smallest_group() :: {String.t(), non_neg_integer()} | nil
  def smallest_group, do: extreme_group(&Enum.min_by/2)

  # Picks the group with the extreme replica count using `pick` (Enum.max_by or
  # Enum.min_by), breaking ties by group id order. Returns `nil` when empty.
  defp extreme_group(pick) do
    case group_sizes() do
      sizes when map_size(sizes) == 0 ->
        nil

      sizes ->
        sizes
        |> Enum.sort_by(&elem(&1, 0))
        |> pick.(&elem(&1, 1))
    end
  end

  @doc """
  Returns the maximum replica lag (in offsets) across all groups, or `0` when
  there are no tracked replicas. A quick worst-case staleness indicator.
  """
  @spec max_lag() :: non_neg_integer()
  def max_lag do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.map(&Map.get(&1, :lag, 0))
    |> case do
      [] -> 0
      lags -> Enum.max(lags)
    end
  end

  @doc """
  Returns the minimum replica lag (in offsets) across all groups — the most
  caught-up replica. `0` when there are no tracked replicas.
  """
  @spec min_lag() :: non_neg_integer()
  def min_lag do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.map(&Map.get(&1, :lag, 0))
    |> case do
      [] -> 0
      lags -> Enum.min(lags)
    end
  end

  @doc """
  Returns the total replica lag (sum of offsets) across all groups — a rough
  aggregate backlog indicator. `0` when there are no tracked replicas.
  """
  @spec total_lag() :: non_neg_integer()
  def total_lag do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.map(&Map.get(&1, :lag, 0))
    |> Enum.sum()
  end

  @doc """
  Returns the ids of replicas that are lagging or stale, as `{group_id, node_id}`
  tuples, sorted. Useful for targeted catch-up scheduling.
  """
  @spec unhealthy_replicas() :: [{String.t(), NodeId.t()}]
  def unhealthy_replicas do
    for group <- all_groups(),
        {node_id, replica} <- Map.get(group, :replicas, %{}),
        Map.get(replica, :status, :healthy) != :healthy do
      {group.group_id, node_id}
    end
    |> Enum.sort_by(fn {group_id, node_id} -> {group_id, node_id.value} end)
  end

  @doc """
  Returns the total number of tracked replicas that are fully caught up (lag of
  `0`) across all groups.
  """
  @spec in_sync_count() :: non_neg_integer()
  def in_sync_count do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.count(&(Map.get(&1, :lag, 0) == 0))
  end

  @doc """
  Returns the number of tracked replicas that are behind the leader (lag greater
  than `0`) across all groups.
  """
  @spec behind_count() :: non_neg_integer()
  def behind_count do
    all_groups()
    |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
    |> Enum.count(&(Map.get(&1, :lag, 0) > 0))
  end

  @doc """
  Returns the average replica lag (in offsets) across all tracked replicas, or
  `0.0` when there are no replicas.
  """
  @spec avg_lag() :: float()
  def avg_lag do
    lags =
      all_groups()
      |> Enum.flat_map(fn group -> Map.values(Map.get(group, :replicas, %{})) end)
      |> Enum.map(&Map.get(&1, :lag, 0))

    case lags do
      [] -> 0.0
      _ -> Enum.sum(lags) / length(lags)
    end
  end

  @doc """
  Returns the fraction of tracked replicas that are fully caught up (0.0..1.0),
  or `1.0` when there are no replicas. A quick replication-health indicator.
  """
  @spec sync_ratio() :: float()
  def sync_ratio do
    case replica_count() do
      0 -> 1.0
      total -> in_sync_count() / total
    end
  end

  @doc """
  Returns the fraction of replication groups that are fully healthy (no lagging
  or stale replica), 0.0..1.0. Returns `1.0` when there are no groups.
  """
  @spec healthy_group_ratio() :: float()
  def healthy_group_ratio do
    case group_count() do
      0 -> 1.0
      total -> (total - unhealthy_group_count()) / total
    end
  end

  @doc """
  Returns a compact one-call replication overview: group and replica counts,
  in-sync count, sync ratio, max lag, and overall health.
  """
  @spec overview() :: %{
          groups: non_neg_integer(),
          replicas: non_neg_integer(),
          in_sync: non_neg_integer(),
          sync_ratio: float(),
          max_lag: non_neg_integer(),
          healthy: boolean()
        }
  def overview do
    %{
      groups: group_count(),
      replicas: replica_count(),
      in_sync: in_sync_count(),
      sync_ratio: sync_ratio(),
      max_lag: max_lag(),
      healthy: healthy?()
    }
  end

  @doc """
  Returns the number of replication groups.
  """
  @spec group_count() :: non_neg_integer()
  def group_count, do: length(all_groups())
end
