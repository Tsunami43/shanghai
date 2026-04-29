defmodule Cluster.Events.NodeRecovered do
  @moduledoc """
  Event emitted when a previously-unavailable node becomes reachable again, for
  example when its Erlang distribution connection is re-established after a
  network partition heals.
  """

  alias CoreDomain.Types.NodeId

  @type recovery_method :: :connection_restored | :heartbeat | :manual

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          recovery_method: recovery_method(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:node_id, :recovery_method, :timestamp, :metadata]

  @doc """
  Creates a new NodeRecovered event.
  """
  @spec new(NodeId.t(), recovery_method(), map()) :: t()
  def new(node_id, recovery_method \\ :connection_restored, metadata \\ %{}) do
    %__MODULE__{
      node_id: node_id,
      recovery_method: recovery_method,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defimpl CoreDomain.Protocols.Event do
    def event_type(_event), do: :node_recovered

    def timestamp(%{timestamp: timestamp}), do: timestamp

    def metadata(%{metadata: metadata}), do: metadata
  end
end
