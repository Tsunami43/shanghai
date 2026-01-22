defmodule Replication.ValueObjects.ReplicationOffset do
  @moduledoc """
  Represents a position in the replication log.

  ReplicationOffset tracks where a replica is in terms of applying
  the leader's write-ahead log. This is crucial for:
  - Determining replica lag
  - Resuming replication after disconnection
  - Ensuring proper ordering of operations
  """

  @type t :: %__MODULE__{
          value: non_neg_integer()
        }

  defstruct value: 0

  @doc """
  Creates a new ReplicationOffset.
  """
  @spec new(non_neg_integer()) :: t()
  def new(value) when is_integer(value) and value >= 0 do
    %__MODULE__{value: value}
  end

  @doc """
  Creates a ReplicationOffset only when `value` is a non-negative integer,
  returning `{:ok, offset}` or `{:error, :invalid}`. The validating counterpart
  to `new/1`.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid}
  def parse(value) when is_integer(value) and value >= 0, do: {:ok, new(value)}
  def parse(_value), do: {:error, :invalid}

  @doc """
  Returns the zero offset (start of replication).
  """
  @spec zero() :: t()
  def zero, do: %__MODULE__{value: 0}

  @doc """
  Increments the offset by 1.
  """
  @spec increment(t()) :: t()
  def increment(%__MODULE__{value: value}) do
    %__MODULE__{value: value + 1}
  end

  @doc """
  Decrements the offset by 1, clamping at `0` (offsets are non-negative).
  """
  @spec decrement(t()) :: t()
  def decrement(%__MODULE__{value: 0}), do: %__MODULE__{value: 0}
  def decrement(%__MODULE__{value: value}), do: %__MODULE__{value: value - 1}

  @doc """
  Advances the offset by a given amount.
  """
  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{value: value}, amount) when is_integer(amount) and amount >= 0 do
    %__MODULE__{value: value + amount}
  end

  @doc """
  Rewinds the offset by `amount` positions (`amount >= 0`), clamping at `0`.
  """
  @spec rewind(t(), non_neg_integer()) :: t()
  def rewind(%__MODULE__{value: value}, amount) when is_integer(amount) and amount >= 0 do
    %__MODULE__{value: max(value - amount, 0)}
  end

  @doc """
  Returns the inclusive list of offsets from `first` to `last`. Empty when
  `last` precedes `first`. Useful for enumerating a replica catch-up window.
  """
  @spec range(t(), t()) :: [t()]
  def range(%__MODULE__{value: first}, %__MODULE__{value: last}) when last >= first do
    Enum.map(first..last, &new/1)
  end

  def range(%__MODULE__{}, %__MODULE__{}), do: []

  @doc """
  Returns the number of offsets in the inclusive range `first..last`, or `0` when
  `last` precedes `first` — the size of the catch-up window without building the
  list.
  """
  @spec count_between(t(), t()) :: non_neg_integer()
  def count_between(%__MODULE__{value: first}, %__MODULE__{value: last}) when last >= first do
    last - first + 1
  end

  def count_between(%__MODULE__{}, %__MODULE__{}), do: 0

  @doc """
  Compares two offsets.
  Returns :lt, :eq, or :gt.
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
  Returns true if this offset is behind the other.
  """
  @spec behind?(t(), t()) :: boolean()
  def behind?(%__MODULE__{} = offset1, %__MODULE__{} = offset2) do
    compare(offset1, offset2) == :lt
  end

  @doc "Returns `true` when this offset is ahead of (greater than) the other."
  @spec ahead?(t(), t()) :: boolean()
  def ahead?(%__MODULE__{} = offset1, %__MODULE__{} = offset2) do
    compare(offset1, offset2) == :gt
  end

  @doc "Returns `true` when this offset has reached or passed `target`."
  @spec caught_up?(t(), t()) :: boolean()
  def caught_up?(%__MODULE__{value: current}, %__MODULE__{value: target}) do
    current >= target
  end

  @doc """
  Returns `true` when this offset is strictly before `target` (still behind and
  not yet caught up). The complement of `caught_up?/2`.
  """
  @spec pending?(t(), t()) :: boolean()
  def pending?(%__MODULE__{value: current}, %__MODULE__{value: target}) do
    current < target
  end

  @doc "Returns the raw integer value of an offset."
  @spec to_integer(t()) :: non_neg_integer()
  def to_integer(%__MODULE__{value: value}), do: value

  @doc "Returns `true` when the offset value is a whole multiple of `n`."
  @spec multiple_of?(t(), pos_integer()) :: boolean()
  def multiple_of?(%__MODULE__{value: value}, n) when is_integer(n) and n > 0 do
    rem(value, n) == 0
  end

  @doc """
  Returns `true` when this offset is at or before `target` (has not yet passed
  it).
  """
  @spec at_or_before?(t(), t()) :: boolean()
  def at_or_before?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a <= b

  @doc """
  Returns `true` when this offset is at or after `target` (has reached or passed
  it).
  """
  @spec at_or_after?(t(), t()) :: boolean()
  def at_or_after?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a >= b

  @doc "Returns `true` when the offset is past the start (value greater than 0)."
  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{value: 0}), do: false
  def positive?(%__MODULE__{}), do: true

  @doc """
  Returns a display string for the offset in the form `Offset(n)`.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: "Offset(#{value})"

  @doc "Returns `true` when the two offsets are equal."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a == b

  @doc "Returns `true` when the two offsets differ."
  @spec differ?(t(), t()) :: boolean()
  def differ?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a != b

  @doc "Returns `true` when the offset is within the inclusive range `[low, high]`."
  @spec between?(t(), t(), t()) :: boolean()
  def between?(%__MODULE__{value: v}, %__MODULE__{value: low}, %__MODULE__{value: high}) do
    v >= low and v <= high
  end

  @doc """
  Clamps an offset to the inclusive range `[low, high]`: returns `low` when below
  it, `high` when above it, otherwise the offset unchanged.
  """
  @spec clamp(t(), t(), t()) :: t()
  def clamp(%__MODULE__{value: v}, %__MODULE__{value: low}, %__MODULE__{value: high})
      when low <= high do
    cond do
      v < low -> new(low)
      v > high -> new(high)
      true -> new(v)
    end
  end

  @doc "Returns `true` when the offset is at the start of the log (value 0)."
  @spec initial?(t()) :: boolean()
  def initial?(%__MODULE__{value: 0}), do: true
  def initial?(%__MODULE__{}), do: false

  @doc """
  Returns the average of a non-empty list of offsets as an offset (integer
  division). Raises on an empty list.
  """
  @spec average([t(), ...]) :: t()
  def average([_ | _] = offsets) do
    new(div(sum(offsets), length(offsets)))
  end

  @doc "Returns the later (greater) of two offsets."
  @spec later(t(), t()) :: t()
  def later(%__MODULE__{value: a} = off_a, %__MODULE__{value: b} = off_b) do
    if a >= b, do: off_a, else: off_b
  end

  @doc """
  Returns the greatest offset in a non-empty list (the replication watermark).
  Raises when the list is empty.
  """
  @spec max_of([t(), ...]) :: t()
  def max_of([first | rest]) do
    Enum.reduce(rest, first, &later/2)
  end

  @doc """
  Returns the sum of a list of offset values as a raw integer. Empty list sums
  to `0`.
  """
  @spec sum([t()]) :: non_neg_integer()
  def sum(offsets) when is_list(offsets) do
    Enum.reduce(offsets, 0, fn %__MODULE__{value: v}, acc -> acc + v end)
  end

  @doc "Sorts a list of offsets in descending order."
  @spec sort_desc([t()]) :: [t()]
  def sort_desc(offsets) when is_list(offsets), do: Enum.sort_by(offsets, & &1.value, :desc)

  @doc "Sorts a list of offsets in ascending order."
  @spec sort([t()]) :: [t()]
  def sort(offsets) when is_list(offsets), do: Enum.sort_by(offsets, & &1.value)

  @doc """
  Returns the smallest offset in a non-empty list (the slowest replica).
  Raises when the list is empty.
  """
  @spec min_of([t(), ...]) :: t()
  def min_of([first | rest]) do
    Enum.reduce(rest, first, &earlier/2)
  end

  @doc """
  Returns the span of a non-empty list of offsets as `{min, max}`. Raises when
  the list is empty.
  """
  @spec span([t(), ...]) :: {t(), t()}
  def span([_ | _] = offsets), do: {min_of(offsets), max_of(offsets)}

  @doc """
  Returns the median offset of a non-empty list. For an even count the lower of
  the two middle values is returned. Raises on an empty list.
  """
  @spec median([t(), ...]) :: t()
  def median([_ | _] = offsets) do
    sorted = sort(offsets)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  @doc "Returns the earlier (lesser) of two offsets."
  @spec earlier(t(), t()) :: t()
  def earlier(%__MODULE__{value: a} = off_a, %__MODULE__{value: b} = off_b) do
    if a <= b, do: off_a, else: off_b
  end

  @doc "Clamps an offset to be at least `floor`."
  @spec at_least(t(), t()) :: t()
  def at_least(%__MODULE__{value: v} = off, %__MODULE__{value: floor}) do
    if v < floor, do: new(floor), else: off
  end

  @doc "Clamps an offset to be at most `ceiling`."
  @spec at_most(t(), t()) :: t()
  def at_most(%__MODULE__{value: v} = off, %__MODULE__{value: ceiling}) do
    if v > ceiling, do: new(ceiling), else: off
  end

  @doc """
  Returns the midpoint offset between two offsets (integer division). Useful for
  bisecting a replication window.
  """
  @spec midpoint(t(), t()) :: t()
  def midpoint(%__MODULE__{value: a}, %__MODULE__{value: b}), do: new(div(a + b, 2))

  @doc """
  Returns the arithmetic difference `later - earlier` of the two offsets as an
  offset, regardless of argument order (always non-negative).
  """
  @spec distance(t(), t()) :: t()
  def distance(%__MODULE__{value: a}, %__MODULE__{value: b}), do: new(abs(a - b))

  @doc """
  Calculates the lag (difference) between two offsets.
  """
  @spec lag(t(), t()) :: non_neg_integer()
  def lag(%__MODULE__{value: current}, %__MODULE__{value: target}) when target >= current do
    target - current
  end

  def lag(_, _), do: 0

  @doc """
  Returns how far `current` has caught up to `target` as a fraction in
  `0.0..1.0`. A target at offset `0` is treated as fully caught up (`1.0`), and
  the result is capped at `1.0` when `current` is ahead.
  """
  @spec catch_up_ratio(t(), t()) :: float()
  def catch_up_ratio(%__MODULE__{value: current}, %__MODULE__{value: target}) do
    cond do
      target <= 0 -> 1.0
      current >= target -> 1.0
      true -> current / target
    end
  end

  @doc """
  Returns the signed difference `b - a` between two offsets. Positive when `b`
  is ahead of `a`, negative when behind. Unlike `lag/2`, this never clamps.

  ## Examples

      iex> alias Replication.ValueObjects.ReplicationOffset, as: Offset
      iex> Offset.delta(Offset.new(3), Offset.new(10))
      7
      iex> Offset.delta(Offset.new(10), Offset.new(3))
      -7
  """
  @spec delta(t(), t()) :: integer()
  def delta(%__MODULE__{value: a}, %__MODULE__{value: b}), do: b - a
end
