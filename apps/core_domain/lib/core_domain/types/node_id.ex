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
  Returns `true` when `value` is a non-empty binary suitable for a NodeId.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_binary(value) and value != ""

  @doc """
  Returns the underlying string value of a NodeId.

  ## Examples

      iex> CoreDomain.Types.NodeId.new("node-1") |> CoreDomain.Types.NodeId.to_string()
      "node-1"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  @doc """
  Compares two NodeIds by their string value. Returns `:lt`, `:eq`, or `:gt`.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{value: a}, %__MODULE__{value: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc "Returns `true` when the NodeId's value starts with `prefix`."
  @spec starts_with?(t(), String.t()) :: boolean()
  def starts_with?(%__MODULE__{value: value}, prefix) when is_binary(prefix) do
    String.starts_with?(value, prefix)
  end

  @doc """
  Returns a shortened, display-friendly form of the id, keeping the first
  `length` characters (default 8). Values already at or below `length` are
  returned unchanged.

  ## Examples

      iex> CoreDomain.Types.NodeId.new("abcdef0123456789") |> CoreDomain.Types.NodeId.short(6)
      "abcdef"
  """
  @spec short(t(), pos_integer()) :: String.t()
  def short(%__MODULE__{value: value}, length \\ 8)
      when is_integer(length) and length > 0 do
    if String.length(value) <= length, do: value, else: String.slice(value, 0, length)
  end
end
