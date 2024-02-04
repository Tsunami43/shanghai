defmodule Replication.ValueObjects.ConsistencyLevel do
  @moduledoc """
  Represents the consistency level for read and write operations.

  Consistency levels control the trade-off between consistency,
  availability, and latency:

  - `:local` - Only local node, fastest but no durability guarantee
  - `:quorum` - Majority of replicas, balanced consistency/availability
  - `:leader` - Leader confirmation only, strong ordering guarantee
  """

  @type level :: :local | :quorum | :leader
  @type t :: %__MODULE__{level: level()}

  defstruct [:level]

  @doc """
  Creates a new ConsistencyLevel.
  """
  @spec new(level()) :: t()
  def new(level) when level in [:local, :quorum, :leader] do
    %__MODULE__{level: level}
  end

  @doc """
  Returns the default consistency level.
  """
  @spec default() :: t()
  def default do
    new(:quorum)
  end

  @doc """
  Returns all valid consistency levels as structs, from weakest to strongest
  durability guarantee: `:local`, `:quorum`, `:leader`.
  """
  @spec all() :: [t()]
  def all, do: Enum.map([:local, :quorum, :leader], &new/1)

  @doc "Returns `true` when two consistency levels are equal."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{level: a}, %__MODULE__{level: b}), do: a == b

  @doc """
  Returns the ordinal strength of a level by durability guarantee: `:local` (0)
  < `:quorum` (1) < `:leader` (2).
  """
  @spec rank(t()) :: 0..2
  def rank(%__MODULE__{level: :local}), do: 0
  def rank(%__MODULE__{level: :quorum}), do: 1
  def rank(%__MODULE__{level: :leader}), do: 2

  @doc "Compares two levels by strength. Returns `:lt`, `:eq`, or `:gt`."
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    cond do
      rank(a) < rank(b) -> :lt
      rank(a) > rank(b) -> :gt
      true -> :eq
    end
  end

  @doc """
  Returns true if this level requires quorum.
  """
  @spec requires_quorum?(t()) :: boolean()
  def requires_quorum?(%__MODULE__{level: :quorum}), do: true
  def requires_quorum?(%__MODULE__{level: _}), do: false

  @doc """
  Returns true if this level only requires leader acknowledgment.
  """
  @spec requires_leader_only?(t()) :: boolean()
  def requires_leader_only?(%__MODULE__{level: :leader}), do: true
  def requires_leader_only?(%__MODULE__{level: _}), do: false

  @doc """
  Returns true if this level is local only (no replication wait).
  """
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{level: :local}), do: true
  def local?(%__MODULE__{level: _}), do: false

  @doc """
  Calculates required acknowledgments for a given replica count.

  Returns the number of replicas that must acknowledge a write.
  """
  @spec required_acks(t(), pos_integer()) :: pos_integer()
  def required_acks(%__MODULE__{level: :local}, _replica_count), do: 1
  def required_acks(%__MODULE__{level: :leader}, _replica_count), do: 1

  def required_acks(%__MODULE__{level: :quorum}, replica_count) do
    div(replica_count, 2) + 1
  end

  @doc """
  Returns a string representation of the consistency level.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{level: level}), do: Atom.to_string(level)

  @doc """
  Parses a consistency level from a string or atom.
  """
  @spec parse(String.t() | atom()) :: {:ok, t()} | {:error, :invalid_consistency_level}
  def parse(level) when is_atom(level) and level in [:local, :quorum, :leader] do
    {:ok, new(level)}
  end

  def parse(level) when is_binary(level) do
    case level do
      "local" -> {:ok, new(:local)}
      "quorum" -> {:ok, new(:quorum)}
      "leader" -> {:ok, new(:leader)}
      _ -> {:error, :invalid_consistency_level}
    end
  end

  def parse(_), do: {:error, :invalid_consistency_level}
end
