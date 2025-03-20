defmodule Cluster.Entities.Node do
  @moduledoc """
  Represents a node in the Shanghai cluster.

  A node is identified by its NodeId and tracks connection information
  (host/port) and current status (up, down, suspect).
  """

  alias CoreDomain.Types.NodeId

  @type status :: :up | :down | :suspect

  @type t :: %__MODULE__{
          id: NodeId.t(),
          host: String.t(),
          port: non_neg_integer(),
          status: status(),
          metadata: map(),
          last_seen_at: DateTime.t() | nil
        }

  defstruct [:id, :host, :port, :status, :metadata, :last_seen_at]

  @doc """
  Creates a new Node entity.

  ## Examples

      iex> node_id = CoreDomain.Types.NodeId.new("node1")
      iex> Cluster.Entities.Node.new(node_id, "localhost", 4000)
      %Cluster.Entities.Node{
        id: node_id,
        host: "localhost",
        port: 4000,
        status: :up,
        metadata: %{},
        last_seen_at: nil
      }
  """
  @spec new(NodeId.t(), String.t(), non_neg_integer(), map()) :: t()
  def new(id, host, port, metadata \\ %{}) do
    %__MODULE__{
      id: id,
      host: host,
      port: port,
      status: :up,
      metadata: metadata,
      last_seen_at: DateTime.utc_now()
    }
  end

  @doc """
  Marks a node as up and updates last_seen_at timestamp.
  """
  @spec mark_up(t()) :: t()
  def mark_up(%__MODULE__{} = node) do
    %{node | status: :up, last_seen_at: DateTime.utc_now()}
  end

  @doc """
  Marks a node as down.
  """
  @spec mark_down(t()) :: t()
  def mark_down(%__MODULE__{} = node) do
    %{node | status: :down}
  end

  @doc """
  Marks a node as suspect (potentially down, awaiting confirmation).
  """
  @spec mark_suspect(t()) :: t()
  def mark_suspect(%__MODULE__{} = node) do
    %{node | status: :suspect}
  end

  @doc """
  Applies a status transition by name: `:up`, `:down`, or `:suspect`. Delegates
  to the corresponding `mark_*` function so timestamps stay consistent.
  """
  @spec with_status(t(), status()) :: t()
  def with_status(%__MODULE__{} = node, :up), do: mark_up(node)
  def with_status(%__MODULE__{} = node, :down), do: mark_down(node)
  def with_status(%__MODULE__{} = node, :suspect), do: mark_suspect(node)

  @doc """
  Returns true if the node is currently up.
  """
  @spec up?(t()) :: boolean()
  def up?(%__MODULE__{status: :up}), do: true
  def up?(%__MODULE__{}), do: false

  @doc """
  Returns true if the node is currently down.
  """
  @spec down?(t()) :: boolean()
  def down?(%__MODULE__{status: :down}), do: true
  def down?(%__MODULE__{}), do: false

  @doc """
  Returns true if the node is currently suspect.
  """
  @spec suspect?(t()) :: boolean()
  def suspect?(%__MODULE__{status: :suspect}), do: true
  def suspect?(%__MODULE__{}), do: false

  @doc "Returns `true` when the node has one of the given statuses."
  @spec status_in?(t(), [status()]) :: boolean()
  def status_in?(%__MODULE__{status: status}, statuses) when is_list(statuses) do
    status in statuses
  end

  @doc """
  Updates node metadata.
  """
  @spec update_metadata(t(), map()) :: t()
  def update_metadata(%__MODULE__{} = node, metadata) when is_map(metadata) do
    %{node | metadata: Map.merge(node.metadata, metadata)}
  end

  @doc """
  Updates the last_seen_at timestamp to current time.
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = node) do
    %{node | last_seen_at: DateTime.utc_now()}
  end

  @doc """
  Returns the node's network address as a `host:port` string.
  """
  @spec address(t()) :: String.t()
  def address(%__MODULE__{host: host, port: port}), do: "#{host}:#{port}"

  @doc "Returns `true` when the node listens on `port`."
  @spec on_port?(t(), non_neg_integer()) :: boolean()
  def on_port?(%__MODULE__{port: port}, port), do: true
  def on_port?(%__MODULE__{}, _port), do: false

  @doc "Returns `true` when the node runs on `host`."
  @spec on_host?(t(), String.t()) :: boolean()
  def on_host?(%__MODULE__{host: host}, host), do: true
  def on_host?(%__MODULE__{}, _host), do: false

  @doc "Returns `true` when the node's address equals `address` (`host:port`)."
  @spec at_address?(t(), String.t()) :: boolean()
  def at_address?(%__MODULE__{} = node, address) when is_binary(address) do
    address(node) == address
  end

  @doc "Returns `true` when two nodes are on the same host."
  @spec same_host?(t(), t()) :: boolean()
  def same_host?(%__MODULE__{host: host}, %__MODULE__{host: host}), do: true
  def same_host?(%__MODULE__{}, %__MODULE__{}), do: false

  @doc "Returns `true` when two nodes share the same `host:port` address."
  @spec same_address?(t(), t()) :: boolean()
  def same_address?(%__MODULE__{} = a, %__MODULE__{} = b), do: address(a) == address(b)

  @doc "Returns `true` when the two nodes have the same id."
  @spec same_id?(t(), t()) :: boolean()
  def same_id?(%__MODULE__{id: id}, %__MODULE__{id: id}), do: true
  def same_id?(%__MODULE__{}, %__MODULE__{}), do: false

  @doc """
  Returns `true` when the node's id string starts with `prefix`. Useful for
  filtering nodes by an id namespace.
  """
  @spec id_starts_with?(t(), String.t()) :: boolean()
  def id_starts_with?(%__MODULE__{id: %NodeId{value: value}}, prefix) when is_binary(prefix) do
    String.starts_with?(value, prefix)
  end

  @doc "Returns the node's id as its string value."
  @spec id_value(t()) :: String.t()
  def id_value(%__MODULE__{id: %NodeId{value: value}}), do: value

  @doc """
  Returns a compact human-readable description of the node in the form
  `id@host:port (status)`. Useful for logs and CLI output.

  ## Examples

      iex> node = Cluster.Entities.Node.new(CoreDomain.Types.NodeId.new("n1"), "localhost", 4000)
      iex> Cluster.Entities.Node.describe(node)
      "n1@localhost:4000 (up)"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{id: %NodeId{value: value}, status: status} = node) do
    "#{value}@#{address(node)} (#{status})"
  end

  @doc "Returns `true` when the node is not `:up` (`:down` or `:suspect`)."
  @spec unavailable?(t()) :: boolean()
  def unavailable?(%__MODULE__{status: :up}), do: false
  def unavailable?(%__MODULE__{}), do: true

  @doc """
  Returns `true` when the node is reachable for serving traffic — i.e. it is
  `:up`. The inverse of `unavailable?/1`, spelled for routing readability.
  """
  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{status: :up}), do: true
  def available?(%__MODULE__{}), do: false

  @doc "Returns `true` when the node has never reported a heartbeat."
  @spec never_seen?(t()) :: boolean()
  def never_seen?(%__MODULE__{last_seen_at: nil}), do: true
  def never_seen?(%__MODULE__{}), do: false

  @doc "Returns `true` when the node has reported at least one heartbeat."
  @spec seen?(t()) :: boolean()
  def seen?(%__MODULE__{last_seen_at: nil}), do: false
  def seen?(%__MODULE__{}), do: true

  @doc """
  Returns the age of the node's last heartbeat in milliseconds, or `nil` when it
  has never been seen.
  """
  @spec last_seen_age_ms(t()) :: non_neg_integer() | nil
  def last_seen_age_ms(%__MODULE__{last_seen_at: nil}), do: nil

  def last_seen_age_ms(%__MODULE__{last_seen_at: seen}) do
    DateTime.diff(DateTime.utc_now(), seen, :millisecond)
  end

  @doc """
  Returns the age of the node's last heartbeat in whole seconds, or `nil` when
  it has never been seen.
  """
  @spec last_seen_age_seconds(t()) :: non_neg_integer() | nil
  def last_seen_age_seconds(%__MODULE__{last_seen_at: nil}), do: nil

  def last_seen_age_seconds(%__MODULE__{last_seen_at: seen}) do
    DateTime.diff(DateTime.utc_now(), seen, :second)
  end

  @doc """
  Returns `true` when the node's last heartbeat is older than `threshold_ms`. A
  node that has never been seen is considered stale.
  """
  @spec stale?(t(), non_neg_integer()) :: boolean()
  def stale?(%__MODULE__{last_seen_at: nil}, _threshold_ms), do: true

  def stale?(%__MODULE__{} = node, threshold_ms) when is_integer(threshold_ms) do
    last_seen_age_ms(node) > threshold_ms
  end

  @doc """
  Returns the Erlang node name for this node.
  """
  @spec erlang_node_name(t()) :: atom()
  def erlang_node_name(%__MODULE__{id: %NodeId{value: value}, host: host}) do
    String.to_atom("#{value}@#{host}")
  end

  @doc """
  Returns `true` when this node's Erlang node name matches `Node.self/0` — i.e.
  it represents the current runtime node.
  """
  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{} = node) do
    erlang_node_name(node) == :erlang.node()
  end

  @doc """
  Returns a plain-map view of the node for serialization, with the id as its
  string value and the address rendered as `host:port`.
  """
  @spec to_map(t()) :: %{
          id: String.t(),
          address: String.t(),
          host: String.t(),
          port: non_neg_integer(),
          status: status(),
          metadata: map(),
          last_seen_at: DateTime.t() | nil
        }
  def to_map(%__MODULE__{id: %NodeId{value: value}} = node) do
    %{
      id: value,
      address: address(node),
      host: node.host,
      port: node.port,
      status: node.status,
      metadata: node.metadata,
      last_seen_at: node.last_seen_at
    }
  end

  @doc """
  Rebuilds a node from a plain map produced by `to_map/1`, wrapping the id
  string back into a `NodeId`. `metadata` defaults to `%{}`, `status` to `:up`,
  and `last_seen_at` to `nil` when absent.
  """
  @spec from_map(map()) :: t()
  def from_map(%{id: id, host: host, port: port} = map) do
    %__MODULE__{
      id: NodeId.new(id),
      host: host,
      port: port,
      status: Map.get(map, :status, :up),
      metadata: Map.get(map, :metadata, %{}),
      last_seen_at: Map.get(map, :last_seen_at)
    }
  end
end
