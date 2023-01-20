defmodule Cluster.ValueObjects.NodeMetadata do
  @moduledoc """
  Metadata associated with a cluster node.

  NodeMetadata provides additional context about a node including:
  - Node capabilities and features
  - Resource availability
  - Configuration parameters
  - Custom tags and labels
  """

  @type t :: %__MODULE__{
          capabilities: MapSet.t(atom()),
          tags: map(),
          resources: map(),
          version: String.t()
        }

  defstruct capabilities: MapSet.new(),
            tags: %{},
            resources: %{},
            version: "0.1.0"

  @doc """
  Creates new NodeMetadata with default values.

  ## Examples

      iex> Cluster.ValueObjects.NodeMetadata.new()
      %Cluster.ValueObjects.NodeMetadata{
        capabilities: MapSet.new(),
        tags: %{},
        resources: %{},
        version: "0.1.0"
      }
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      capabilities: opts[:capabilities] || MapSet.new(),
      tags: opts[:tags] || %{},
      resources: opts[:resources] || %{},
      version: opts[:version] || "0.1.0"
    }
  end

  @doc """
  Adds a capability to the metadata.
  """
  @spec add_capability(t(), atom()) :: t()
  def add_capability(%__MODULE__{capabilities: caps} = metadata, capability)
      when is_atom(capability) do
    %{metadata | capabilities: MapSet.put(caps, capability)}
  end

  @doc """
  Returns true if the node has the specified capability.
  """
  @spec has_capability?(t(), atom()) :: boolean()
  def has_capability?(%__MODULE__{capabilities: caps}, capability) do
    MapSet.member?(caps, capability)
  end

  @doc """
  Adds or updates a tag.
  """
  @spec put_tag(t(), atom() | String.t(), any()) :: t()
  def put_tag(%__MODULE__{tags: tags} = metadata, key, value) do
    %{metadata | tags: Map.put(tags, key, value)}
  end

  @doc """
  Returns the value of a tag, or nil if not present.
  """
  @spec get_tag(t(), atom() | String.t(), any()) :: any()
  def get_tag(%__MODULE__{tags: tags}, key, default \\ nil) do
    Map.get(tags, key, default)
  end

  @doc """
  Updates resource information.
  """
  @spec update_resources(t(), map()) :: t()
  def update_resources(%__MODULE__{resources: resources} = metadata, new_resources)
      when is_map(new_resources) do
    %{metadata | resources: Map.merge(resources, new_resources)}
  end

  @doc """
  Converts metadata to a map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = metadata) do
    %{
      capabilities: MapSet.to_list(metadata.capabilities),
      tags: metadata.tags,
      resources: metadata.resources,
      version: metadata.version
    }
  end

  @doc """
  Creates metadata from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      capabilities: MapSet.new(map[:capabilities] || map["capabilities"] || []),
      tags: map[:tags] || map["tags"] || %{},
      resources: map[:resources] || map["resources"] || %{},
      version: map[:version] || map["version"] || "0.1.0"
    }
  end
end
