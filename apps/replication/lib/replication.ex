defmodule Replication do
  @moduledoc """
  Public API for Shanghai Replication functionality.

  Provides access to replication group information, monitoring,
  and metrics for all replicated shards.
  """

  alias Replication.Monitor

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
