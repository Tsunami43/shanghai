defmodule Cluster.Events.NodeJoined do
  @moduledoc """
  Event emitted when a node successfully joins the cluster.
  """

  alias Cluster.Entities.Node
  alias CoreDomain.Types.NodeId

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          node: Node.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:node_id, :node, :timestamp, :metadata]

  @doc """
  Creates a new NodeJoined event.
  """
  @spec new(Node.t(), map()) :: t()
  def new(%Node{id: node_id} = node, metadata \\ %{}) do
    %__MODULE__{
      node_id: node_id,
      node: node,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :node_joined

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
