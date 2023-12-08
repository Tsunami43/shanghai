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
  Returns the zero LSN — the starting point of a fresh log.

  ## Examples

      iex> CoreDomain.Types.LogSequenceNumber.zero().value
      0
  """
  @spec zero() :: t()
  def zero, do: new(0)

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

  @doc """
  Returns the raw integer value of an LSN.

  ## Examples

      iex> CoreDomain.Types.LogSequenceNumber.to_integer(CoreDomain.Types.LogSequenceNumber.new(9))
      9
  """
  @spec to_integer(t()) :: non_neg_integer()
  def to_integer(%__MODULE__{value: value}), do: value

  @doc """
  Returns the later (greater) of two LSNs.

  ## Examples

      iex> a = CoreDomain.Types.LogSequenceNumber.new(3)
      iex> b = CoreDomain.Types.LogSequenceNumber.new(7)
      iex> CoreDomain.Types.LogSequenceNumber.later(a, b).value
      7
  """
  @spec later(t(), t()) :: t()
  def later(%__MODULE__{value: a} = lsn_a, %__MODULE__{value: b} = lsn_b) do
    if a >= b, do: lsn_a, else: lsn_b
  end

  @doc """
  Returns the earlier (lesser) of two LSNs.

  ## Examples

      iex> a = CoreDomain.Types.LogSequenceNumber.new(3)
      iex> b = CoreDomain.Types.LogSequenceNumber.new(7)
      iex> CoreDomain.Types.LogSequenceNumber.earlier(a, b).value
      3
  """
  @spec earlier(t(), t()) :: t()
  def earlier(%__MODULE__{value: a} = lsn_a, %__MODULE__{value: b} = lsn_b) do
    if a <= b, do: lsn_a, else: lsn_b
  end

  @doc """
  Advances an LSN by `n` positions (`n >= 0`).

  ## Examples

      iex> lsn = CoreDomain.Types.LogSequenceNumber.new(10)
      iex> CoreDomain.Types.LogSequenceNumber.advance(lsn, 5).value
      15
  """
  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{value: v}, n) when is_integer(n) and n >= 0 do
    new(v + n)
  end

  @doc """
  Returns the number of positions `b` is ahead of `a` (`b - a`), or `0` when `a`
  is at or ahead of `b`.

  ## Examples

      iex> a = CoreDomain.Types.LogSequenceNumber.new(3)
      iex> b = CoreDomain.Types.LogSequenceNumber.new(10)
      iex> CoreDomain.Types.LogSequenceNumber.distance(a, b)
      7
  """
  @spec distance(t(), t()) :: non_neg_integer()
  def distance(%__MODULE__{value: a}, %__MODULE__{value: b}) when b >= a, do: b - a
  def distance(%__MODULE__{}, %__MODULE__{}), do: 0

  @doc """
  Returns `true` when `lsn` is within the inclusive range `[low, high]`.

  ## Examples

      iex> alias CoreDomain.Types.LogSequenceNumber, as: LSN
      iex> LSN.between?(LSN.new(5), LSN.new(1), LSN.new(10))
      true
  """
  @spec between?(t(), t(), t()) :: boolean()
  def between?(%__MODULE__{value: v}, %__MODULE__{value: low}, %__MODULE__{value: high}) do
    v >= low and v <= high
  end
end
