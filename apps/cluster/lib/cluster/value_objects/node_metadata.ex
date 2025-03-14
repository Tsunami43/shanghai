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
  Removes a capability from the metadata (idempotent).
  """
  @spec remove_capability(t(), atom()) :: t()
  def remove_capability(%__MODULE__{capabilities: caps} = metadata, capability)
      when is_atom(capability) do
    %{metadata | capabilities: MapSet.delete(caps, capability)}
  end

  @doc """
  Returns the capabilities as a sorted list.
  """
  @spec capabilities(t()) :: [atom()]
  def capabilities(%__MODULE__{capabilities: caps}), do: caps |> MapSet.to_list() |> Enum.sort()

  @doc """
  Returns the capabilities present in `metadata` but not in `other` (the extra
  capabilities `metadata` advertises), as a sorted list.
  """
  @spec extra_capabilities(t(), t()) :: [atom()]
  def extra_capabilities(%__MODULE__{capabilities: a}, %__MODULE__{capabilities: b}) do
    a |> MapSet.difference(b) |> MapSet.to_list() |> Enum.sort()
  end

  @doc "Returns the number of capabilities the node advertises."
  @spec capability_count(t()) :: non_neg_integer()
  def capability_count(%__MODULE__{capabilities: caps}), do: MapSet.size(caps)

  @doc """
  Returns `true` when the metadata advertises any capability at all.
  """
  @spec any_capabilities?(t()) :: boolean()
  def any_capabilities?(%__MODULE__{capabilities: caps}), do: MapSet.size(caps) > 0

  @doc "Returns `true` when the metadata carries any tags."
  @spec any_tags?(t()) :: boolean()
  def any_tags?(%__MODULE__{tags: tags}), do: map_size(tags) > 0

  @doc "Returns `true` when the metadata carries any resources."
  @spec any_resources?(t()) :: boolean()
  def any_resources?(%__MODULE__{resources: resources}), do: map_size(resources) > 0

  @doc """
  Returns `true` when the metadata has all the given capabilities.
  """
  @spec has_all_capabilities?(t(), [atom()]) :: boolean()
  def has_all_capabilities?(%__MODULE__{capabilities: caps}, required) when is_list(required) do
    Enum.all?(required, &MapSet.member?(caps, &1))
  end

  @doc """
  Returns the required capabilities that the metadata is missing, as a sorted
  list. Empty when all are present.
  """
  @spec missing_capabilities(t(), [atom()]) :: [atom()]
  def missing_capabilities(%__MODULE__{capabilities: caps}, required) when is_list(required) do
    required
    |> Enum.reject(&MapSet.member?(caps, &1))
    |> Enum.sort()
  end

  @doc """
  Returns `true` when the metadata has any of the given capabilities.
  """
  @spec has_any_capability?(t(), [atom()]) :: boolean()
  def has_any_capability?(%__MODULE__{capabilities: caps}, candidates) when is_list(candidates) do
    Enum.any?(candidates, &MapSet.member?(caps, &1))
  end

  @doc """
  Returns the capabilities that both metadata values share, as a sorted list.
  """
  @spec common_capabilities(t(), t()) :: [atom()]
  def common_capabilities(%__MODULE__{capabilities: a}, %__MODULE__{capabilities: b}) do
    a |> MapSet.intersection(b) |> MapSet.to_list() |> Enum.sort()
  end

  @doc "Returns the number of tags set on the metadata."
  @spec tag_count(t()) :: non_neg_integer()
  def tag_count(%__MODULE__{tags: tags}), do: map_size(tags)

  @doc "Returns the number of resource entries set on the metadata."
  @spec resource_count(t()) :: non_neg_integer()
  def resource_count(%__MODULE__{resources: resources}), do: map_size(resources)

  @doc "Returns `true` when a tag with `key` is set."
  @spec has_tag?(t(), atom() | String.t()) :: boolean()
  def has_tag?(%__MODULE__{tags: tags}, key), do: Map.has_key?(tags, key)

  @doc "Returns `true` when a resource with `key` is set."
  @spec has_resource?(t(), atom() | String.t()) :: boolean()
  def has_resource?(%__MODULE__{resources: resources}, key), do: Map.has_key?(resources, key)

  @doc "Returns `true` when the tag `key` is set to exactly `value`."
  @spec tagged?(t(), atom() | String.t(), any()) :: boolean()
  def tagged?(%__MODULE__{tags: tags}, key, value), do: Map.get(tags, key) == value

  @doc "Returns the full tags map."
  @spec tags(t()) :: map()
  def tags(%__MODULE__{tags: tags}), do: tags

  @doc """
  Returns the tag values for the given tag keys, in key order, using `default`
  for absent keys.
  """
  @spec tag_values(t(), [atom() | String.t()], any()) :: [any()]
  def tag_values(%__MODULE__{tags: tags}, keys, default \\ nil) when is_list(keys) do
    Enum.map(keys, &Map.get(tags, &1, default))
  end

  @doc "Returns the tag keys, sorted."
  @spec tag_keys(t()) :: [atom() | String.t()]
  def tag_keys(%__MODULE__{tags: tags}), do: tags |> Map.keys() |> Enum.sort()

  @doc "Removes a tag by key (idempotent)."
  @spec delete_tag(t(), atom() | String.t()) :: t()
  def delete_tag(%__MODULE__{tags: tags} = metadata, key) do
    %{metadata | tags: Map.delete(tags, key)}
  end

  @doc "Removes a resource by key (idempotent)."
  @spec delete_resource(t(), atom() | String.t()) :: t()
  def delete_resource(%__MODULE__{resources: resources} = metadata, key) do
    %{metadata | resources: Map.delete(resources, key)}
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

  @doc "Returns the full resources map."
  @spec resources(t()) :: map()
  def resources(%__MODULE__{resources: resources}), do: resources

  @doc "Returns the resource value for `key`, or the metadata's default when absent, coerced to an integer via `get_resource/3`."
  @spec resource_or(t(), atom() | String.t(), integer()) :: integer()
  def resource_or(%__MODULE__{} = metadata, key, default) when is_integer(default) do
    case get_resource(metadata, key, default) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  @doc "Returns a copy of the metadata with its version set to `version`."
  @spec with_version(t(), String.t()) :: t()
  def with_version(%__MODULE__{} = metadata, version) when is_binary(version) do
    %{metadata | version: version}
  end

  @doc """
  Returns `true` when the two metadata values share the same version string.
  """
  @spec same_version?(t(), t()) :: boolean()
  def same_version?(%__MODULE__{version: a}, %__MODULE__{version: b}), do: a == b

  @doc """
  Returns `true` when the metadata satisfies a placement requirement: it has
  every capability in `:capabilities` and every `key => value` in `:tags`. Both
  requirement keys are optional and default to empty.

  ## Examples

      iex> md =
      ...>   Cluster.ValueObjects.NodeMetadata.new()
      ...>   |> Cluster.ValueObjects.NodeMetadata.add_capability(:storage)
      ...>   |> Cluster.ValueObjects.NodeMetadata.put_tag(:region, "eu")
      iex> Cluster.ValueObjects.NodeMetadata.satisfies?(md, %{capabilities: [:storage], tags: %{region: "eu"}})
      true
  """
  @spec satisfies?(t(), map()) :: boolean()
  def satisfies?(%__MODULE__{} = metadata, requirement) when is_map(requirement) do
    caps = Map.get(requirement, :capabilities, [])
    tags = Map.get(requirement, :tags, %{})

    has_all_capabilities?(metadata, caps) and
      Enum.all?(tags, fn {key, value} -> get_tag(metadata, key) == value end)
  end

  @doc "Returns the resource keys, sorted."
  @spec resource_keys(t()) :: [atom() | String.t()]
  def resource_keys(%__MODULE__{resources: resources}), do: resources |> Map.keys() |> Enum.sort()

  @doc "Returns a resource value by key, or `default` when absent."
  @spec get_resource(t(), atom() | String.t(), any()) :: any()
  def get_resource(%__MODULE__{resources: resources}, key, default \\ nil) do
    Map.get(resources, key, default)
  end

  @doc """
  Merges two metadata values: the union of capabilities, and the right-hand
  tags/resources taking precedence on key conflicts. The version comes from the
  right-hand metadata.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      capabilities: MapSet.union(left.capabilities, right.capabilities),
      tags: Map.merge(left.tags, right.tags),
      resources: Map.merge(left.resources, right.resources),
      version: right.version
    }
  end

  @doc """
  Merges a list of metadata values left-to-right via `merge/2`. Returns fresh
  default metadata for an empty list.
  """
  @spec merge_all([t()]) :: t()
  def merge_all([]), do: new()
  def merge_all([first | rest]), do: Enum.reduce(rest, first, &merge(&2, &1))

  @doc """
  Returns `true` when the metadata carries no capabilities, tags, or resources
  (regardless of the version string).
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{capabilities: caps, tags: tags, resources: resources}) do
    MapSet.size(caps) == 0 and map_size(tags) == 0 and map_size(resources) == 0
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
