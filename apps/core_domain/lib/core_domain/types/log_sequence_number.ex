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
  Returns the LSN immediately before this one, or `nil` for the zero LSN.

  ## Examples

      iex> CoreDomain.Types.LogSequenceNumber.predecessor(CoreDomain.Types.LogSequenceNumber.new(5)).value
      4
      iex> CoreDomain.Types.LogSequenceNumber.predecessor(CoreDomain.Types.LogSequenceNumber.zero())
      nil
  """
  @spec predecessor(t()) :: t() | nil
  def predecessor(%__MODULE__{value: 0}), do: nil
  def predecessor(%__MODULE__{value: v}), do: new(v - 1)

  @doc """
  Returns `true` when `b` immediately follows `a` (`b == a + 1`), i.e. the two
  LSNs are contiguous with no gap in the log.

  ## Examples

      iex> alias CoreDomain.Types.LogSequenceNumber, as: LSN
      iex> LSN.contiguous?(LSN.new(4), LSN.new(5))
      true
      iex> LSN.contiguous?(LSN.new(4), LSN.new(6))
      false
  """
  @spec contiguous?(t(), t()) :: boolean()
  def contiguous?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: b == a + 1

  @doc """
  Returns the raw integer value of an LSN.

  ## Examples

      iex> CoreDomain.Types.LogSequenceNumber.to_integer(CoreDomain.Types.LogSequenceNumber.new(9))
      9
  """
  @spec to_integer(t()) :: non_neg_integer()
  def to_integer(%__MODULE__{value: value}), do: value

  @doc """
  Returns a display string for the LSN in the form `"LSN(n)"`.

  ## Examples

      iex> CoreDomain.Types.LogSequenceNumber.to_string(CoreDomain.Types.LogSequenceNumber.new(7))
      "LSN(7)"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: "LSN(#{value})"

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

  @doc "Returns the greatest LSN in a non-empty list. Raises on an empty list."
  @spec max_of([t(), ...]) :: t()
  def max_of([first | rest]), do: Enum.reduce(rest, first, &later/2)

  @doc "Returns the smallest LSN in a non-empty list. Raises on an empty list."
  @spec min_of([t(), ...]) :: t()
  def min_of([first | rest]), do: Enum.reduce(rest, first, &earlier/2)

  @doc "Returns `true` when the LSN is the zero (initial) LSN."
  @spec initial?(t()) :: boolean()
  def initial?(%__MODULE__{value: 0}), do: true
  def initial?(%__MODULE__{}), do: false

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
  Returns the inclusive list of LSNs from `first` to `last`. Empty when `last`
  precedes `first`.

  ## Examples

      iex> alias CoreDomain.Types.LogSequenceNumber, as: LSN
      iex> LSN.range(LSN.new(2), LSN.new(4)) |> Enum.map(& &1.value)
      [2, 3, 4]
  """
  @spec range(t(), t()) :: [t()]
  def range(%__MODULE__{value: first}, %__MODULE__{value: last}) when last >= first do
    Enum.map(first..last, &new/1)
  end

  def range(%__MODULE__{}, %__MODULE__{}), do: []

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
  Returns the signed difference `b - a` between two LSNs. Positive when `b` is
  ahead of `a`, negative when behind. Unlike `distance/2`, this never clamps.

  ## Examples

      iex> alias CoreDomain.Types.LogSequenceNumber, as: LSN
      iex> LSN.diff(LSN.new(3), LSN.new(10))
      7
      iex> LSN.diff(LSN.new(10), LSN.new(3))
      -7
  """
  @spec diff(t(), t()) :: integer()
  def diff(%__MODULE__{value: a}, %__MODULE__{value: b}), do: b - a

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
