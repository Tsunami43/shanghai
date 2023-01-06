defmodule CoreDomain.Types.NodeId do
  @moduledoc """
  Unique identifier for a node in the cluster.

  Node IDs are used for:
  - Identifying nodes in membership management
  - Routing queries and writes
  - Vector clock timestamps
  """

  @type t :: %__MODULE__{
          value: String.t()
        }

  defstruct [:value]

  @doc """
  Creates a new NodeId from a string value.
  """
  @spec new(String.t()) :: t()
  def new(value) when is_binary(value) do
    %__MODULE__{value: value}
  end

  @doc """
  Generates a random NodeId (useful for testing).
  """
  @spec generate() :: t()
  def generate do
    # TODO: Use better ID generation (e.g., Snowflake IDs)
    value = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    new(value)
  end

  @doc """
  Compares two NodeIds for equality.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a == b
end
