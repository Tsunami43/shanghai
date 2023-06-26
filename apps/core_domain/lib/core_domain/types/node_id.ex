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
  Generates a random NodeId.

  Uses 128 bits of cryptographically strong randomness, hex-encoded — a 32-char
  identifier that is collision-resistant for cluster use.
  """
  @spec generate() :: t()
  def generate do
    value = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    new(value)
  end

  @doc """
  Compares two NodeIds for equality.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{value: a}, %__MODULE__{value: b}), do: a == b

  @doc """
  Returns the underlying string value of a NodeId.

  ## Examples

      iex> CoreDomain.Types.NodeId.new("node-1") |> CoreDomain.Types.NodeId.to_string()
      "node-1"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end
