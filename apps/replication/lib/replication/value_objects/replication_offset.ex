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
  Advances the offset by a given amount.
  """
  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{value: value}, amount) when is_integer(amount) and amount >= 0 do
    %__MODULE__{value: value + amount}
  end

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

  @doc "Returns the raw integer value of an offset."
  @spec to_integer(t()) :: non_neg_integer()
  def to_integer(%__MODULE__{value: value}), do: value

  @doc "Returns `true` when the two offsets are equal."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a == b

  @doc "Returns the later (greater) of two offsets."
  @spec later(t(), t()) :: t()
  def later(%__MODULE__{value: a} = off_a, %__MODULE__{value: b} = off_b) do
    if a >= b, do: off_a, else: off_b
  end

  @doc "Returns the earlier (lesser) of two offsets."
  @spec earlier(t(), t()) :: t()
  def earlier(%__MODULE__{value: a} = off_a, %__MODULE__{value: b} = off_b) do
    if a <= b, do: off_a, else: off_b
  end

  @doc """
  Calculates the lag (difference) between two offsets.
  """
  @spec lag(t(), t()) :: non_neg_integer()
  def lag(%__MODULE__{value: current}, %__MODULE__{value: target}) when target >= current do
    target - current
  end

  def lag(_, _), do: 0
end
