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

  @doc "Returns `true` when the NodeId's value contains `substring`."
  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{value: value}, substring) when is_binary(substring) do
    String.contains?(value, substring)
  end

  @doc "Sorts a list of NodeIds by their string value, ascending."
  @spec sort([t()]) :: [t()]
  def sort(node_ids) when is_list(node_ids), do: Enum.sort_by(node_ids, & &1.value)

  @doc """
  Returns the distinct NodeIds from a list, preserving first-seen order.
  Deduplicates by string value.
  """
  @spec uniq([t()]) :: [t()]
  def uniq(node_ids) when is_list(node_ids), do: Enum.uniq_by(node_ids, & &1.value)

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

  @doc """
  Returns a deterministic, non-negative hash of the node id. Stable across
  processes and nodes for a given id — suitable for consistent placement.
  """
  @spec hash(t()) :: non_neg_integer()
  def hash(%__MODULE__{value: value}), do: :erlang.phash2(value)

  @doc """
  Maps the node id deterministically onto one of `slots` buckets (`0..slots-1`).
  Useful for sharding or ring placement.

  ## Examples

      iex> slot = CoreDomain.Types.NodeId.slot(CoreDomain.Types.NodeId.new("n1"), 16)
      iex> slot >= 0 and slot < 16
      true
  """
  @spec slot(t(), pos_integer()) :: non_neg_integer()
  def slot(%__MODULE__{value: value}, slots) when is_integer(slots) and slots > 0 do
    :erlang.phash2(value, slots)
  end
end
