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

  @doc """
  Sorts a list of log entries by LSN in ascending order (WAL/replay order).
  """
  @spec sort([t()]) :: [t()]
  def sort(entries) when is_list(entries) do
    Enum.sort_by(entries, &LogSequenceNumber.to_integer(&1.lsn))
  end

  @doc """
  Sorts a list of log entries by LSN in descending order (newest first).
  """
  @spec sort_desc([t()]) :: [t()]
  def sort_desc(entries) when is_list(entries) do
    Enum.sort_by(entries, &LogSequenceNumber.to_integer(&1.lsn), :desc)
  end

  @doc """
  Returns `true` when a list of entries is contiguous by LSN (no gaps): each
  entry's LSN is exactly one greater than the previous, in the given order. An
  empty or single-entry list is trivially contiguous.
  """
  @spec contiguous?([t()]) :: boolean()
  def contiguous?(entries) when is_list(entries) do
    entries
    |> Enum.map(&LogSequenceNumber.to_integer(&1.lsn))
    |> consecutive?()
  end

  defp consecutive?([]), do: true
  defp consecutive?([_single]), do: true

  defp consecutive?([a, b | rest]) when b == a + 1, do: consecutive?([b | rest])
  defp consecutive?(_), do: false

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

  @doc "Returns the entries produced by `node_id`, in their given order."
  @spec from_node([t()], NodeId.t()) :: [t()]
  def from_node(entries, node_id) when is_list(entries) do
    Enum.filter(entries, &(&1.node_id == node_id))
  end

  @doc """
  Returns the entries whose LSN falls within the inclusive range `[low, high]`,
  in their given order.
  """
  @spec in_lsn_range([t()], LogSequenceNumber.t(), LogSequenceNumber.t()) :: [t()]
  def in_lsn_range(entries, low, high) when is_list(entries) do
    Enum.filter(entries, &LogSequenceNumber.between?(&1.lsn, low, high))
  end

  @doc """
  Returns the entry with the highest LSN in a non-empty list. Raises on an empty
  list.
  """
  @spec max_by_lsn([t(), ...]) :: t()
  def max_by_lsn([_ | _] = entries) do
    Enum.max_by(entries, &LogSequenceNumber.to_integer(&1.lsn))
  end

  @doc """
  Returns the entry with the lowest LSN in a non-empty list. Raises on an empty
  list.
  """
  @spec min_by_lsn([t(), ...]) :: t()
  def min_by_lsn([_ | _] = entries) do
    Enum.min_by(entries, &LogSequenceNumber.to_integer(&1.lsn))
  end

  @doc """
  Returns the distinct node ids that produced the entries in a list, sorted by
  their string value.
  """
  @spec node_ids([t()]) :: [NodeId.t()]
  def node_ids(entries) when is_list(entries) do
    entries
    |> Enum.map(& &1.node_id)
    |> Enum.uniq_by(& &1.value)
    |> Enum.sort_by(& &1.value)
  end

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

  @doc "Returns the entry's producing node id as its string value."
  @spec node_id_value(t()) :: String.t()
  def node_id_value(%__MODULE__{node_id: node_id}), do: NodeId.to_string(node_id)

  @doc """
  Returns a compact human-readable description of the entry in the form
  `LSN(n) from <node_id>`. Useful for logs.

  ## Examples

      iex> lsn = CoreDomain.Types.LogSequenceNumber.new(7)
      iex> id = CoreDomain.Types.NodeId.new("n1")
      iex> CoreDomain.Entities.LogEntry.describe(CoreDomain.Entities.LogEntry.new(lsn, "d", id))
      "LSN(7) from n1"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{lsn: lsn, node_id: %NodeId{value: value}}) do
    "#{LogSequenceNumber.to_string(lsn)} from #{value}"
  end

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

  @doc "Returns the sorted metadata keys of the entry."
  @spec metadata_keys(t()) :: [term()]
  def metadata_keys(%__MODULE__{metadata: metadata}), do: metadata |> Map.keys() |> Enum.sort()

  @doc "Returns a copy of the entry with `key` set to `value` in its metadata."
  @spec put_metadata(t(), term(), term()) :: t()
  def put_metadata(%__MODULE__{metadata: metadata} = entry, key, value) do
    %{entry | metadata: Map.put(metadata, key, value)}
  end

  @doc "Returns a copy of the entry with `key` removed from its metadata."
  @spec delete_metadata(t(), term()) :: t()
  def delete_metadata(%__MODULE__{metadata: metadata} = entry, key) do
    %{entry | metadata: Map.delete(metadata, key)}
  end

  @doc """
  Returns a copy of the entry with `fields` merged into its metadata; keys in
  `fields` take precedence.
  """
  @spec merge_metadata(t(), map()) :: t()
  def merge_metadata(%__MODULE__{metadata: metadata} = entry, fields) when is_map(fields) do
    %{entry | metadata: Map.merge(metadata, fields)}
  end

  @doc "Returns `true` when the entry's metadata contains `key`."
  @spec has_metadata?(t(), term()) :: boolean()
  def has_metadata?(%__MODULE__{metadata: metadata}, key), do: Map.has_key?(metadata, key)

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
