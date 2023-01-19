defmodule Cluster.Events.NodeDetectedDown do
  @moduledoc """
  Event emitted when a node is detected as down (failed heartbeat, network partition, etc.).
  """

  alias CoreDomain.Types.NodeId

  @type detection_method :: :heartbeat_failure | :network_partition | :manual

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          detection_method: detection_method(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:node_id, :detection_method, :timestamp, :metadata]

  @doc """
  Creates a new NodeDetectedDown event.
  """
  @spec new(NodeId.t(), detection_method(), map()) :: t()
  def new(node_id, detection_method \\ :heartbeat_failure, metadata \\ %{}) do
    %__MODULE__{
      node_id: node_id,
      detection_method: detection_method,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :node_detected_down

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
