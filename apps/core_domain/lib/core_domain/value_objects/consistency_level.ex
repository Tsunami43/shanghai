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
end
