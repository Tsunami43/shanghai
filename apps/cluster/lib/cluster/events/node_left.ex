defmodule Cluster.Events.NodeLeft do
  @moduledoc """
  Event emitted when a node gracefully leaves the cluster.
  """

  alias CoreDomain.Types.NodeId

  @type reason :: :graceful | :timeout | :requested

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          reason: reason(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:node_id, :reason, :timestamp, :metadata]

  @doc """
  Creates a new NodeLeft event.
  """
  @spec new(NodeId.t(), reason(), map()) :: t()
  def new(node_id, reason \\ :graceful, metadata \\ %{}) do
    %__MODULE__{
      node_id: node_id,
      reason: reason,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :node_left

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
