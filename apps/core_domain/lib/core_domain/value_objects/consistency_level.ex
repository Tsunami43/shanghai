defmodule CoreDomain.ValueObjects.ConsistencyLevel do
  @moduledoc """
  Consistency level for read and write operations.

  Defines the consistency semantics for operations:
  - `:strong` - Strong consistency (quorum read/write)
  - `:eventual` - Eventual consistency (local read, async replication)
  - `:causal` - Causal consistency (preserves causal order)
  """

  @type t :: :strong | :eventual | :causal

  @valid_levels [:strong, :eventual, :causal]

  @doc """
  Validates a consistency level.
  """
  @spec valid?(atom()) :: boolean()
  def valid?(level) when level in @valid_levels, do: true
  def valid?(_), do: false

  @doc """
  Returns all valid consistency levels.
  """
  @spec all() :: [t()]
  def all, do: @valid_levels

  @doc """
  Parses a consistency level from a string or atom without creating new atoms
  (safe for untrusted input such as HTTP query parameters or config values).

  Returns `{:ok, level}` or `{:error, :invalid_consistency}`.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.parse("strong")
      {:ok, :strong}

      iex> CoreDomain.ValueObjects.ConsistencyLevel.parse("nonsense")
      {:error, :invalid_consistency}
  """
  @spec parse(String.t() | atom()) :: {:ok, t()} | {:error, :invalid_consistency}
  def parse(level) when level in @valid_levels, do: {:ok, level}
  def parse("strong"), do: {:ok, :strong}
  def parse("eventual"), do: {:ok, :eventual}
  def parse("causal"), do: {:ok, :causal}
  def parse(_), do: {:error, :invalid_consistency}

  @doc """
  Returns the default consistency level.
  """
  @spec default() :: t()
  def default, do: :strong

  @doc """
  Checks if a level is stronger than another.
  """
  @spec stronger_than?(t(), t()) :: boolean()
  def stronger_than?(:strong, :eventual), do: true
  def stronger_than?(:strong, :causal), do: true
  def stronger_than?(:causal, :eventual), do: true
  def stronger_than?(_, _), do: false

  @doc """
  Returns the ordinal strength of a level: `:eventual` (0) < `:causal` (1) <
  `:strong` (2). Useful for sorting or comparing levels numerically.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.rank(:causal)
      1
  """
  @spec rank(t()) :: 0..2
  def rank(:eventual), do: 0
  def rank(:causal), do: 1
  def rank(:strong), do: 2

  @doc """
  Compares two levels by strength. Returns `:lt`, `:eq`, or `:gt`.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.compare(:eventual, :strong)
      :lt
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(a, b) do
    cond do
      rank(a) < rank(b) -> :lt
      rank(a) > rank(b) -> :gt
      true -> :eq
    end
  end

  @doc """
  Returns the stronger of two consistency levels.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.stronger(:eventual, :strong)
      :strong
  """
  @spec stronger(t(), t()) :: t()
  def stronger(a, b) do
    if stronger_than?(b, a), do: b, else: a
  end

  @doc """
  Returns the weaker of two consistency levels.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.weaker(:strong, :eventual)
      :eventual
  """
  @spec weaker(t(), t()) :: t()
  def weaker(a, b) do
    if stronger_than?(a, b), do: b, else: a
  end
end
