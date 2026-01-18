defmodule Replication.ReplicaGroup do
  @moduledoc """
  ReplicaGroup aggregate - manages a replicated shard.

  The ReplicaGroup is responsible for:
  - Tracking all replicas in the group
  - Managing leader election and role assignment
  - Enforcing write ordering through the leader
  - Monitoring replica health and lag
  - Emitting events for replication changes
  """

  alias CoreDomain.Types.NodeId
  alias Replication.Entities.Replica
  alias Replication.Events.{LeaderElected, ReplicaCaughtUp, ReplicaFellBehind}
  alias Replication.ValueObjects.ReplicationOffset

  @type t :: %__MODULE__{
          group_id: String.t(),
          replicas: %{NodeId.t() => Replica.t()},
          leader_node_id: NodeId.t() | nil,
          term: non_neg_integer(),
          events: [struct()]
        }

  defstruct group_id: nil,
            replicas: %{},
            leader_node_id: nil,
            term: 0,
            events: []

  @doc """
  Creates a new ReplicaGroup.
  """
  @spec new(String.t()) :: t()
  def new(group_id) do
    %__MODULE__{
      group_id: group_id,
      replicas: %{},
      leader_node_id: nil,
      term: 0,
      events: []
    }
  end

  @doc """
  Adds a replica to the group as a follower.
  """
  @spec add_replica(t(), NodeId.t()) :: {:ok, t()} | {:error, atom()}
  def add_replica(%__MODULE__{replicas: replicas} = group, node_id) do
    if Map.has_key?(replicas, node_id) do
      {:error, :replica_already_exists}
    else
      replica = Replica.new_follower(node_id)
      updated_replicas = Map.put(replicas, node_id, replica)
      {:ok, %{group | replicas: updated_replicas}}
    end
  end

  @doc """
  Elects a leader for the group.
  """
  @spec elect_leader(t(), NodeId.t()) :: {:ok, t()} | {:error, atom()}
  def elect_leader(%__MODULE__{replicas: replicas, term: term} = group, node_id) do
    case Map.fetch(replicas, node_id) do
      {:ok, _replica} ->
        # Demote current leader if exists
        updated_replicas =
          if group.leader_node_id do
            Map.update!(replicas, group.leader_node_id, &Replica.demote_to_follower/1)
          else
            replicas
          end

        # Promote new leader
        updated_replicas =
          Map.update!(updated_replicas, node_id, &Replica.promote_to_leader/1)

        new_term = term + 1
        event = LeaderElected.new(group.group_id, node_id, new_term)

        updated_group = %{
          group
          | replicas: updated_replicas,
            leader_node_id: node_id,
            term: new_term,
            events: [event | group.events]
        }

        {:ok, updated_group}

      :error ->
        {:error, :replica_not_found}
    end
  end

  @doc """
  Updates a replica's offset.
  """
  @spec update_replica_offset(t(), NodeId.t(), ReplicationOffset.t()) ::
          {:ok, t()} | {:error, atom()}
  def update_replica_offset(%__MODULE__{replicas: replicas} = group, node_id, offset) do
    case Map.fetch(replicas, node_id) do
      {:ok, replica} ->
        updated_replica = Replica.update_offset(replica, offset)
        updated_replicas = Map.put(replicas, node_id, updated_replica)

        # Check if replica caught up
        updated_group =
          if replica.status == :lagging and updated_replica.status != :lagging do
            event = ReplicaCaughtUp.new(group.group_id, node_id, offset)
            %{group | replicas: updated_replicas, events: [event | group.events]}
          else
            %{group | replicas: updated_replicas}
          end

        {:ok, updated_group}

      :error ->
        {:error, :replica_not_found}
    end
  end

  @doc """
  Marks a replica as lagging.
  """
  @spec mark_replica_lagging(t(), NodeId.t(), ReplicationOffset.t()) ::
          {:ok, t()} | {:error, atom()}
  def mark_replica_lagging(%__MODULE__{replicas: replicas} = group, node_id, current_offset) do
    with {:ok, replica} <- Map.fetch(replicas, node_id),
         {:ok, leader} <- get_leader_replica(group) do
      updated_replica = Replica.mark_lagging(replica)
      updated_replicas = Map.put(replicas, node_id, updated_replica)

      event =
        ReplicaFellBehind.new(group.group_id, node_id, current_offset, leader.offset)

      updated_group = %{
        group
        | replicas: updated_replicas,
          events: [event | group.events]
      }

      {:ok, updated_group}
    else
      :error -> {:error, :replica_not_found}
    end
  end

  @doc """
  Gets the leader replica.
  """
  @spec get_leader_replica(t()) :: {:ok, Replica.t()} | {:error, :no_leader}
  def get_leader_replica(%__MODULE__{leader_node_id: nil}), do: {:error, :no_leader}

  def get_leader_replica(%__MODULE__{replicas: replicas, leader_node_id: leader_id}) do
    case Map.fetch(replicas, leader_id) do
      {:ok, replica} -> {:ok, replica}
      :error -> {:error, :no_leader}
    end
  end

  @doc """
  Returns all follower replicas.
  """
  @spec follower_replicas(t()) :: [Replica.t()]
  def follower_replicas(%__MODULE__{replicas: replicas}) do
    replicas
    |> Map.values()
    |> Enum.filter(&Replica.follower?/1)
  end

  @doc """
  Returns all healthy replicas.
  """
  @spec healthy_replicas(t()) :: [Replica.t()]
  def healthy_replicas(%__MODULE__{replicas: replicas}) do
    replicas
    |> Map.values()
    |> Enum.filter(&Replica.healthy?/1)
  end

  @doc """
  Counts replicas that have caught up to a given offset.
  """
  @spec count_caught_up(t(), ReplicationOffset.t()) :: non_neg_integer()
  def count_caught_up(%__MODULE__{replicas: replicas}, target_offset) do
    replicas
    |> Map.values()
    |> Enum.count(fn replica ->
      ReplicationOffset.compare(replica.offset, target_offset) != :lt
    end)
  end

  @doc """
  Returns all pending events and clears the event list.
  """
  @spec take_events(t()) :: {[struct()], t()}
  def take_events(%__MODULE__{events: events} = group) do
    {Enum.reverse(events), %{group | events: []}}
  end

  @doc """
  Returns true if the group has a leader.
  """
  @spec has_leader?(t()) :: boolean()
  def has_leader?(%__MODULE__{leader_node_id: nil}), do: false
  def has_leader?(%__MODULE__{}), do: true
end
