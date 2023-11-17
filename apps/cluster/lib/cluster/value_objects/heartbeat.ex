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
      iex> hb = Cluster.ValueObjects.Heartbeat.new(node_id, 1)
      iex> {hb.node_id, hb.sequence, hb.metrics}
      {CoreDomain.Types.NodeId.new("node1"), 1, %{}}
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

  @doc "Returns `true` when `a` has a higher sequence number than `b`."
  @spec newer_than?(t(), t()) :: boolean()
  def newer_than?(%__MODULE__{sequence: a}, %__MODULE__{sequence: b}), do: a > b

  @doc """
  Returns `true` when the heartbeat is stale: its age exceeds `timeout_ms`.
  """
  @spec stale?(t(), non_neg_integer()) :: boolean()
  def stale?(%__MODULE__{} = heartbeat, timeout_ms) do
    not fresh?(heartbeat, timeout_ms)
  end

  @doc """
  Adds health metrics to the heartbeat.
  """
  @spec with_metrics(t(), map()) :: t()
  def with_metrics(%__MODULE__{} = heartbeat, metrics) when is_map(metrics) do
    %{heartbeat | metrics: Map.merge(heartbeat.metrics, metrics)}
  end
end
