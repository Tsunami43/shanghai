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

  @doc "Returns the number of lagging replicas across all groups."
  @spec lagging_count() :: non_neg_integer()
  def lagging_count, do: length(get_lagging_replicas())

  @doc "Returns the number of stale replicas across all groups."
  @spec stale_count() :: non_neg_integer()
  def stale_count, do: length(get_stale_replicas())

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
  Returns `true` when a replication group with `group_id` is being tracked.
  """
  @spec has_group?(String.t()) :: boolean()
  def has_group?(group_id) do
    match?({:ok, _metrics}, get_group_metrics(group_id))
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
  Returns the number of replication groups.
  """
  @spec group_count() :: non_neg_integer()
  def group_count, do: length(all_groups())
end
