defmodule Replication.Events.LeaderElected do
  @moduledoc """
  Event emitted when a new leader is elected for a replica group.
  """

  alias CoreDomain.Types.NodeId

  @type t :: %__MODULE__{
          group_id: String.t(),
          leader_node_id: NodeId.t(),
          term: non_neg_integer(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:group_id, :leader_node_id, :term, :timestamp, :metadata]

  @doc """
  Creates a new LeaderElected event.
  """
  @spec new(String.t(), NodeId.t(), non_neg_integer(), map()) :: t()
  def new(group_id, leader_node_id, term, metadata \\ %{}) do
    %__MODULE__{
      group_id: group_id,
      leader_node_id: leader_node_id,
      term: term,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :leader_elected

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
