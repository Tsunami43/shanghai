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

  @doc "Returns `true` when `a` has a lower sequence number than `b`."
  @spec older_than?(t(), t()) :: boolean()
  def older_than?(%__MODULE__{sequence: a}, %__MODULE__{sequence: b}), do: a < b

  @doc "Returns `true` when two heartbeats share the same sequence number."
  @spec same_sequence?(t(), t()) :: boolean()
  def same_sequence?(%__MODULE__{sequence: a}, %__MODULE__{sequence: b}), do: a == b

  @doc "Returns the age of the heartbeat in whole seconds."
  @spec age_seconds(t()) :: non_neg_integer()
  def age_seconds(%__MODULE__{timestamp: timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :second)
  end

  @doc "Returns `true` when the heartbeat's age is at most `max_age_ms` (still fresh)."
  @spec within_age?(t(), non_neg_integer()) :: boolean()
  def within_age?(%__MODULE__{} = heartbeat, max_age_ms) do
    fresh?(heartbeat, max_age_ms)
  end

  @doc """
  Returns a compact human-readable description of the heartbeat in the form
  `<node_id> seq=<sequence>`. Useful for logs.

  ## Examples

      iex> hb = Cluster.ValueObjects.Heartbeat.new(CoreDomain.Types.NodeId.new("n1"), 5)
      iex> Cluster.ValueObjects.Heartbeat.describe(hb)
      "n1 seq=5"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{node_id: %NodeId{value: value}, sequence: sequence}) do
    "#{value} seq=#{sequence}"
  end

  @doc """
  Returns the next heartbeat for the same node: the sequence incremented by one,
  a fresh timestamp, and the metrics carried over.
  """
  @spec next(t()) :: t()
  def next(%__MODULE__{node_id: node_id, sequence: sequence, metrics: metrics}) do
    %__MODULE__{
      node_id: node_id,
      sequence: sequence + 1,
      timestamp: DateTime.utc_now(),
      metrics: metrics
    }
  end

  @doc """
  Returns the heartbeat with the higher sequence number. Ties resolve to `a`.
  """
  @spec latest(t(), t()) :: t()
  def latest(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.sequence > a.sequence, do: b, else: a
  end

  @doc """
  Returns `true` when the heartbeat is stale: its age exceeds `timeout_ms`.
  """
  @spec stale?(t(), non_neg_integer()) :: boolean()
  def stale?(%__MODULE__{} = heartbeat, timeout_ms) do
    not fresh?(heartbeat, timeout_ms)
  end

  @doc """
  Returns the number of sequence numbers `b` is ahead of `a` (`b.sequence -
  a.sequence`), or `0` when `a` is at or ahead of `b`. A measure of how many
  heartbeats were missed.
  """
  @spec sequence_gap(t(), t()) :: non_neg_integer()
  def sequence_gap(%__MODULE__{sequence: a}, %__MODULE__{sequence: b}) when b > a, do: b - a
  def sequence_gap(%__MODULE__{}, %__MODULE__{}), do: 0

  @doc """
  Adds health metrics to the heartbeat.
  """
  @spec with_metrics(t(), map()) :: t()
  def with_metrics(%__MODULE__{} = heartbeat, metrics) when is_map(metrics) do
    %{heartbeat | metrics: Map.merge(heartbeat.metrics, metrics)}
  end

  @doc "Returns `true` when the heartbeat carries a metric under `key`."
  @spec has_metric?(t(), term()) :: boolean()
  def has_metric?(%__MODULE__{metrics: metrics}, key), do: Map.has_key?(metrics, key)

  @doc "Returns the value of metric `key`, or `default` when absent."
  @spec get_metric(t(), term(), term()) :: term()
  def get_metric(%__MODULE__{metrics: metrics}, key, default \\ nil) do
    Map.get(metrics, key, default)
  end

  @doc "Returns a copy of the heartbeat with a single metric `key` set to `value`."
  @spec put_metric(t(), term(), term()) :: t()
  def put_metric(%__MODULE__{metrics: metrics} = heartbeat, key, value) do
    %{heartbeat | metrics: Map.put(metrics, key, value)}
  end

  @doc "Returns the metric keys carried by the heartbeat, sorted."
  @spec metric_names(t()) :: [term()]
  def metric_names(%__MODULE__{metrics: metrics}), do: metrics |> Map.keys() |> Enum.sort()

  @doc """
  Returns a copy of the heartbeat with every metric removed. Useful when only
  the liveness signal (node id + sequence + timestamp) is needed.
  """
  @spec without_metrics(t()) :: t()
  def without_metrics(%__MODULE__{} = heartbeat), do: %{heartbeat | metrics: %{}}

  @doc "Returns the number of metrics carried by the heartbeat."
  @spec metric_count(t()) :: non_neg_integer()
  def metric_count(%__MODULE__{metrics: metrics}), do: map_size(metrics)

  @doc """
  Returns the earliest (lowest-sequence) heartbeat of a non-empty list. Raises on
  an empty list.
  """
  @spec earliest_of([t(), ...]) :: t()
  def earliest_of([first | rest]) do
    Enum.reduce(rest, first, fn hb, acc -> if hb.sequence < acc.sequence, do: hb, else: acc end)
  end

  @doc """
  Returns the heartbeat with the higher sequence number of a non-empty list (the
  most recent). Raises on an empty list.
  """
  @spec latest_of([t(), ...]) :: t()
  def latest_of([first | rest]), do: Enum.reduce(rest, first, &latest/2)

  @doc "Returns `true` when the heartbeat carries no metrics."
  @spec metrics_empty?(t()) :: boolean()
  def metrics_empty?(%__MODULE__{metrics: metrics}), do: map_size(metrics) == 0

  @doc """
  Returns a plain-map view of the heartbeat for serialization, with the source
  node id rendered as its string value.
  """
  @spec to_map(t()) :: %{
          node_id: String.t(),
          sequence: non_neg_integer(),
          timestamp: DateTime.t(),
          metrics: map()
        }
  def to_map(%__MODULE__{node_id: %NodeId{value: value}} = heartbeat) do
    %{
      node_id: value,
      sequence: heartbeat.sequence,
      timestamp: heartbeat.timestamp,
      metrics: heartbeat.metrics
    }
  end

  @doc """
  Rebuilds a heartbeat from a plain map produced by `to_map/1`, wrapping the
  node-id string back into a `NodeId`. `metrics` defaults to `%{}` when absent.
  """
  @spec from_map(map()) :: t()
  def from_map(%{node_id: node_id, sequence: sequence, timestamp: timestamp} = map) do
    %__MODULE__{
      node_id: NodeId.new(node_id),
      sequence: sequence,
      timestamp: timestamp,
      metrics: Map.get(map, :metrics, %{})
    }
  end
end
