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
          stale: non_neg_integer()
        }
  def summary do
    groups = all_groups()

    replica_count =
      Enum.reduce(groups, 0, fn group, acc ->
        acc + map_size(Map.get(group, :replicas, %{}))
      end)

    %{
      groups: length(groups),
      replicas: replica_count,
      lagging: length(get_lagging_replicas()),
      stale: length(get_stale_replicas())
    }
  end

  @doc """
  Returns `true` when replication is healthy: no lagging and no stale replicas.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    get_lagging_replicas() == [] and get_stale_replicas() == []
  end
end
