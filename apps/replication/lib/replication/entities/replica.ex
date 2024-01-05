defmodule Replication.Entities.Replica do
  @moduledoc """
  Represents a replica in a replica group.

  A Replica tracks:
  - Node assignment
  - Current role (leader or follower)
  - Replication offset (position in log)
  - Health status
  """

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset

  @type role :: :leader | :follower
  @type status :: :healthy | :lagging | :unavailable

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          role: role(),
          offset: ReplicationOffset.t(),
          status: status(),
          last_heartbeat_at: DateTime.t() | nil
        }

  defstruct [:node_id, :role, :offset, :status, :last_heartbeat_at]

  @doc """
  Creates a new Replica as a follower.
  """
  @spec new_follower(NodeId.t()) :: t()
  def new_follower(node_id) do
    %__MODULE__{
      node_id: node_id,
      role: :follower,
      offset: ReplicationOffset.zero(),
      status: :healthy,
      last_heartbeat_at: DateTime.utc_now()
    }
  end

  @doc """
  Creates a new Replica as a leader.
  """
  @spec new_leader(NodeId.t()) :: t()
  def new_leader(node_id) do
    %__MODULE__{
      node_id: node_id,
      role: :leader,
      offset: ReplicationOffset.zero(),
      status: :healthy,
      last_heartbeat_at: DateTime.utc_now()
    }
  end

  @doc """
  Promotes a follower to leader.
  """
  @spec promote_to_leader(t()) :: t()
  def promote_to_leader(%__MODULE__{} = replica) do
    %{replica | role: :leader}
  end

  @doc """
  Demotes a leader to follower.
  """
  @spec demote_to_follower(t()) :: t()
  def demote_to_follower(%__MODULE__{} = replica) do
    %{replica | role: :follower}
  end

  @doc """
  Updates the replication offset.
  """
  @spec update_offset(t(), ReplicationOffset.t()) :: t()
  def update_offset(%__MODULE__{} = replica, offset) do
    %{replica | offset: offset, last_heartbeat_at: DateTime.utc_now()}
  end

  @doc """
  Marks replica as lagging.
  """
  @spec mark_lagging(t()) :: t()
  def mark_lagging(%__MODULE__{} = replica) do
    %{replica | status: :lagging}
  end

  @doc """
  Marks replica as healthy.
  """
  @spec mark_healthy(t()) :: t()
  def mark_healthy(%__MODULE__{} = replica) do
    %{replica | status: :healthy}
  end

  @doc """
  Marks replica as unavailable.
  """
  @spec mark_unavailable(t()) :: t()
  def mark_unavailable(%__MODULE__{} = replica) do
    %{replica | status: :unavailable}
  end

  @doc """
  Returns true if this replica is the leader.
  """
  @spec leader?(t()) :: boolean()
  def leader?(%__MODULE__{role: :leader}), do: true
  def leader?(_), do: false

  @doc """
  Returns true if this replica is a follower.
  """
  @spec follower?(t()) :: boolean()
  def follower?(%__MODULE__{role: :follower}), do: true
  def follower?(_), do: false

  @doc """
  Returns true if this replica is healthy.
  """
  @spec healthy?(t()) :: boolean()
  def healthy?(%__MODULE__{status: :healthy}), do: true
  def healthy?(_), do: false
end
