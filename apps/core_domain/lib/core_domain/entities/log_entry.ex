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
end
