defmodule Replication.Events.ReplicaCaughtUp do
  @moduledoc """
  Event emitted when a lagging replica catches up to the leader.
  """

  alias CoreDomain.Types.NodeId
  alias Replication.ValueObjects.ReplicationOffset

  @type t :: %__MODULE__{
          group_id: String.t(),
          replica_node_id: NodeId.t(),
          offset: ReplicationOffset.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:group_id, :replica_node_id, :offset, :timestamp, :metadata]

  @doc """
  Creates a new ReplicaCaughtUp event.
  """
  @spec new(String.t(), NodeId.t(), ReplicationOffset.t(), map()) :: t()
  def new(group_id, replica_node_id, offset, metadata \\ %{}) do
    %__MODULE__{
      group_id: group_id,
      replica_node_id: replica_node_id,
      offset: offset,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :replica_caught_up

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
