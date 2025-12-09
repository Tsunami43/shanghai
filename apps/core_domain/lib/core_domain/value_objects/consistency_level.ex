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
  Parses a level and returns it, or raises `ArgumentError` for an invalid one.
  The strict counterpart to `parse/1`.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.parse!("strong")
      :strong
  """
  @spec parse!(String.t() | atom()) :: t()
  def parse!(level) do
    case parse(level) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> raise ArgumentError, "invalid consistency level: #{inspect(level)}"
    end
  end

  @doc """
  Returns all valid consistency levels.
  """
  @spec all() :: [t()]
  def all, do: @valid_levels

  @doc """
  Returns the levels at least as strong as `level` (itself included), sorted from
  weakest to strongest.
  """
  @spec at_least_levels(t()) :: [t()]
  def at_least_levels(level) when level in @valid_levels do
    ordered() |> Enum.filter(&(rank(&1) >= rank(level)))
  end

  @doc """
  Returns the levels no stronger than `level` (itself included), sorted from
  weakest to strongest.
  """
  @spec at_most_levels(t()) :: [t()]
  def at_most_levels(level) when level in @valid_levels do
    ordered() |> Enum.filter(&(rank(&1) <= rank(level)))
  end

  @doc """
  Returns all consistency levels sorted from weakest to strongest by `rank/1`:
  `[:eventual, :causal, :strong]`.
  """
  @spec ordered() :: [t()]
  def ordered, do: Enum.sort_by(@valid_levels, &rank/1)

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

  @doc "Returns the strongest consistency level (`:strong`)."
  @spec strongest() :: t()
  def strongest, do: :strong

  @doc """
  Returns `true` when `level` requires cross-node coordination (`:strong` or
  `:causal`), i.e. it is not purely local (`:eventual`).
  """
  @spec requires_coordination?(t()) :: boolean()
  def requires_coordination?(:eventual), do: false
  def requires_coordination?(level) when level in @valid_levels, do: true

  @doc "Returns the weakest consistency level (`:eventual`)."
  @spec weakest() :: t()
  def weakest, do: :eventual

  @doc """
  Returns `true` when reads at `level` may return stale data (only `:eventual`).
  """
  @spec allows_stale_reads?(t()) :: boolean()
  def allows_stale_reads?(:eventual), do: true
  def allows_stale_reads?(level) when level in @valid_levels, do: false

  @doc """
  Checks if a level is stronger than another.
  """
  @spec stronger_than?(t(), t()) :: boolean()
  def stronger_than?(:strong, :eventual), do: true
  def stronger_than?(:strong, :causal), do: true
  def stronger_than?(:causal, :eventual), do: true
  def stronger_than?(_, _), do: false

  @doc "Checks if a level is weaker than another (the inverse of `stronger_than?/2`)."
  @spec weaker_than?(t(), t()) :: boolean()
  def weaker_than?(a, b), do: stronger_than?(b, a)

  @doc "Returns `true` when `a` is at least as strong as `b` (stronger or equal)."
  @spec at_least?(t(), t()) :: boolean()
  def at_least?(a, b), do: a == b or stronger_than?(a, b)

  @doc "Returns `true` when `a` is no stronger than `b` (weaker or equal)."
  @spec at_most?(t(), t()) :: boolean()
  def at_most?(a, b), do: a == b or weaker_than?(a, b)

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
  Returns the strongest level in a non-empty list. Raises on an empty list.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.strongest_of([:eventual, :strong, :causal])
      :strong
  """
  @spec strongest_of([t(), ...]) :: t()
  def strongest_of([first | rest]), do: Enum.reduce(rest, first, &stronger/2)

  @doc """
  Returns the weakest level in a non-empty list. Raises on an empty list.

  ## Examples

      iex> CoreDomain.ValueObjects.ConsistencyLevel.weakest_of([:strong, :causal, :eventual])
      :eventual
  """
  @spec weakest_of([t(), ...]) :: t()
  def weakest_of([first | rest]), do: Enum.reduce(rest, first, &weaker/2)

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
