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
  Returns the Erlang node name for this node.
  """
  @spec erlang_node_name(t()) :: atom()
  def erlang_node_name(%__MODULE__{id: %NodeId{value: value}, host: host}) do
    String.to_atom("#{value}@#{host}")
  end
end
