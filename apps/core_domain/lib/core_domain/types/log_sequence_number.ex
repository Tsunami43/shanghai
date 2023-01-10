defmodule CoreDomain.Types.LogSequenceNumber do
  @moduledoc """
  Log Sequence Number (LSN) for totally ordering log entries.

  LSNs are monotonically increasing and used for:
  - Ordering events in the WAL
  - Tracking replication progress
  - Implementing consistency guarantees

  ## Examples

      iex> lsn1 = CoreDomain.Types.LogSequenceNumber.new(1)
      iex> lsn2 = CoreDomain.Types.LogSequenceNumber.new(2)
      iex> CoreDomain.Types.LogSequenceNumber.compare(lsn1, lsn2)
      :lt
  """

  @type t :: %__MODULE__{
          value: non_neg_integer()
        }

  defstruct [:value]

  @doc """
  Creates a new LSN with the given value.
  """
  @spec new(non_neg_integer()) :: t()
  def new(value) when is_integer(value) and value >= 0 do
    %__MODULE__{value: value}
  end

  @doc """
  Compares two LSNs.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{value: a}, %__MODULE__{value: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc """
  Increments an LSN by 1.
  """
  @spec increment(t()) :: t()
  def increment(%__MODULE__{value: v}) do
    new(v + 1)
  end

  @doc """
  Returns the next LSN (alias for increment).
  """
  @spec next(t()) :: t()
  def next(lsn), do: increment(lsn)
end
