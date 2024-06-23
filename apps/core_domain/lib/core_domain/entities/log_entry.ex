defmodule CoreDomain.Entities.LogEntry do
  @moduledoc """
  Core log entry entity representing a single entry in the write-ahead log.

  Log entries are immutable and contain:
  - LSN for ordering
  - Data payload
  - Timestamp
  - Metadata
  """

  alias CoreDomain.Types.{LogSequenceNumber, NodeId}

  @type t :: %__MODULE__{
          lsn: LogSequenceNumber.t(),
          data: term(),
          timestamp: DateTime.t(),
          node_id: NodeId.t(),
          metadata: map()
        }

  defstruct [:lsn, :data, :timestamp, :node_id, :metadata]

  @doc """
  Creates a new log entry.
  """
  @spec new(LogSequenceNumber.t(), term(), NodeId.t(), map()) :: t()
  def new(lsn, data, node_id, metadata \\ %{}) do
    %__MODULE__{
      lsn: lsn,
      data: data,
      timestamp: DateTime.utc_now(),
      node_id: node_id,
      metadata: metadata
    }
  end

  @doc """
  Compares two log entries by their LSN.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{lsn: lsn1}, %__MODULE__{lsn: lsn2}) do
    LogSequenceNumber.compare(lsn1, lsn2)
  end

  @doc "Returns `true` when `entry` has a strictly higher LSN than `other`."
  @spec newer_than?(t(), t()) :: boolean()
  def newer_than?(entry, other), do: compare(entry, other) == :gt

  @doc "Returns `true` when `entry` has a strictly lower LSN than `other`."
  @spec older_than?(t(), t()) :: boolean()
  def older_than?(entry, other), do: compare(entry, other) == :lt

  @doc "Returns `true` when two entries share the same LSN."
  @spec same_lsn?(t(), t()) :: boolean()
  def same_lsn?(entry, other), do: compare(entry, other) == :eq

  @doc "Returns `true` when two entries were produced by the same node."
  @spec same_node?(t(), t()) :: boolean()
  def same_node?(%__MODULE__{node_id: a}, %__MODULE__{node_id: b}), do: a == b

  @doc "Returns `true` when the entry was produced by `node_id`."
  @spec from_node?(t(), NodeId.t()) :: boolean()
  def from_node?(%__MODULE__{node_id: node_id}, node_id), do: true
  def from_node?(%__MODULE__{}, _node_id), do: false

  @doc """
  Returns the entry with the higher LSN (the more recent of the two).
  """
  @spec latest(t(), t()) :: t()
  def latest(entry, other) do
    if compare(entry, other) == :lt, do: other, else: entry
  end

  @doc """
  Returns the entry with the lower LSN (the earlier of the two).
  """
  @spec earliest(t(), t()) :: t()
  def earliest(entry, other) do
    if compare(entry, other) == :gt, do: other, else: entry
  end

  @doc "Returns `true` when the entry has no metadata."
  @spec metadata_empty?(t()) :: boolean()
  def metadata_empty?(%__MODULE__{metadata: metadata}), do: map_size(metadata) == 0

  @doc "Returns the entry's LSN as a raw integer."
  @spec lsn_value(t()) :: non_neg_integer()
  def lsn_value(%__MODULE__{lsn: lsn}), do: LogSequenceNumber.to_integer(lsn)

  @doc "Returns the age of the entry in milliseconds since its timestamp."
  @spec age_ms(t()) :: non_neg_integer()
  def age_ms(%__MODULE__{timestamp: timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)
  end

  @doc "Returns the age of the entry in whole seconds since its timestamp."
  @spec age_seconds(t()) :: non_neg_integer()
  def age_seconds(%__MODULE__{timestamp: timestamp}) do
    DateTime.diff(DateTime.utc_now(), timestamp, :second)
  end

  @doc "Returns the metadata value for `key`, or `default` when absent."
  @spec get_metadata(t(), term(), term()) :: term()
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc "Returns a copy of the entry with `key` set to `value` in its metadata."
  @spec put_metadata(t(), term(), term()) :: t()
  def put_metadata(%__MODULE__{metadata: metadata} = entry, key, value) do
    %{entry | metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Returns a plain-map view of the entry for serialization, with the LSN as a raw
  integer and the node id as its string value.
  """
  @spec to_map(t()) :: %{
          lsn: non_neg_integer(),
          data: term(),
          timestamp: DateTime.t(),
          node_id: String.t(),
          metadata: map()
        }
  def to_map(%__MODULE__{} = entry) do
    %{
      lsn: LogSequenceNumber.to_integer(entry.lsn),
      data: entry.data,
      timestamp: entry.timestamp,
      node_id: NodeId.to_string(entry.node_id),
      metadata: entry.metadata
    }
  end

  @doc """
  Rebuilds a log entry from a plain map produced by `to_map/1` (or an equivalent
  with atom keys), wrapping the LSN integer and node-id string back into their
  value objects. `metadata` defaults to `%{}` when absent.
  """
  @spec from_map(map()) :: t()
  def from_map(%{lsn: lsn, data: data, timestamp: timestamp, node_id: node_id} = map) do
    %__MODULE__{
      lsn: LogSequenceNumber.new(lsn),
      data: data,
      timestamp: timestamp,
      node_id: NodeId.new(node_id),
      metadata: Map.get(map, :metadata, %{})
    }
  end
end
