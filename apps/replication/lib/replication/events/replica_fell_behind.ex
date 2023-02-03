defmodule Replication.Events.ReplicaFellBehind do
  @moduledoc """
  Event emitted when a replica falls significantly behind the leader.
  """

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset

  @type t :: %__MODULE__{
          group_id: String.t(),
          replica_node_id: NodeId.t(),
          current_offset: ReplicationOffset.t(),
          leader_offset: ReplicationOffset.t(),
          lag: non_neg_integer(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [
    :group_id,
    :replica_node_id,
    :current_offset,
    :leader_offset,
    :lag,
    :timestamp,
    :metadata
  ]

  @doc """
  Creates a new ReplicaFellBehind event.
  """
  @spec new(String.t(), NodeId.t(), ReplicationOffset.t(), ReplicationOffset.t(), map()) :: t()
  def new(group_id, replica_node_id, current_offset, leader_offset, metadata \\ %{}) do
    lag = ReplicationOffset.lag(current_offset, leader_offset)

    %__MODULE__{
      group_id: group_id,
      replica_node_id: replica_node_id,
      current_offset: current_offset,
      leader_offset: leader_offset,
      lag: lag,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :replica_fell_behind

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
