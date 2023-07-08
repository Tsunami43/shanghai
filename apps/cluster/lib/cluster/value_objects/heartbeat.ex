defmodule Cluster.ValueObjects.Heartbeat do
  @moduledoc """
  Represents a heartbeat signal from a node.

  Heartbeats are used for liveness detection in the cluster.
  Each heartbeat contains:
  - The source node ID
  - Sequence number (monotonically increasing)
  - Timestamp
  - Optional health metrics
  """

  alias CoreDomain.Types.NodeId

  @type t :: %__MODULE__{
          node_id: NodeId.t(),
          sequence: non_neg_integer(),
          timestamp: DateTime.t(),
          metrics: map()
        }

  defstruct [:node_id, :sequence, :timestamp, :metrics]

  @doc """
  Creates a new Heartbeat.

  ## Examples

      iex> node_id = CoreDomain.Types.NodeId.new("node1")
      iex> Cluster.ValueObjects.Heartbeat.new(node_id, 1)
      %Cluster.ValueObjects.Heartbeat{
        node_id: node_id,
        sequence: 1,
        timestamp: ~U[2023-07-01 00:00:00Z],
        metrics: %{}
      }
  """
  @spec new(NodeId.t(), non_neg_integer(), map()) :: t()
  def new(node_id, sequence, metrics \\ %{}) do
    %__MODULE__{
      node_id: node_id,
      sequence: sequence,
      timestamp: DateTime.utc_now(),
      metrics: metrics
    }
  end

  @doc """
  Returns true if this heartbeat is fresh (within timeout threshold).
  """
  @spec fresh?(t(), non_neg_integer()) :: boolean()
  def fresh?(%__MODULE__{timestamp: timestamp}, timeout_ms) do
    age_ms = DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)
    age_ms <= timeout_ms
  end

  @doc """
  Returns the age of the heartbeat in milliseconds.
  """
  @spec age_ms(t()) :: non_neg_integer()
  def age_ms(%__MODULE__{timestamp: timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)
  end

  @doc """
  Adds health metrics to the heartbeat.
  """
  @spec with_metrics(t(), map()) :: t()
  def with_metrics(%__MODULE__{} = heartbeat, metrics) when is_map(metrics) do
    %{heartbeat | metrics: Map.merge(heartbeat.metrics, metrics)}
  end
end
