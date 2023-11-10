defmodule Cluster.ValueObjects.NodeMetadataTest do
  use ExUnit.Case, async: true

  alias Cluster.ValueObjects.NodeMetadata

  doctest NodeMetadata

  test "new/0 uses defaults" do
    md = NodeMetadata.new()

    assert MapSet.size(md.capabilities) == 0
    assert md.tags == %{}
    assert md.resources == %{}
    assert md.version == "0.1.0"
  end

  test "new/1 accepts overrides" do
    md = NodeMetadata.new(version: "1.2.3", tags: %{region: "eu"})

    assert md.version == "1.2.3"
    assert md.tags == %{region: "eu"}
  end

  test "capabilities can be added and queried" do
    md = NodeMetadata.new() |> NodeMetadata.add_capability(:storage)

    assert NodeMetadata.has_capability?(md, :storage)
    refute NodeMetadata.has_capability?(md, :replication)
  end

  test "capabilities/1 returns a sorted list" do
    md =
      NodeMetadata.new()
      |> NodeMetadata.add_capability(:storage)
      |> NodeMetadata.add_capability(:query)

    assert NodeMetadata.capabilities(md) == [:query, :storage]
  end

  test "has_all_capabilities?/2 checks for every required capability" do
    md =
      NodeMetadata.new()
      |> NodeMetadata.add_capability(:storage)
      |> NodeMetadata.add_capability(:query)

    assert NodeMetadata.has_all_capabilities?(md, [:storage, :query])
    assert NodeMetadata.has_all_capabilities?(md, [])
    refute NodeMetadata.has_all_capabilities?(md, [:storage, :replication])
  end

  test "has_any_capability?/2 checks for at least one capability" do
    md = NodeMetadata.new() |> NodeMetadata.add_capability(:storage)

    assert NodeMetadata.has_any_capability?(md, [:replication, :storage])
    refute NodeMetadata.has_any_capability?(md, [:replication, :query])
    refute NodeMetadata.has_any_capability?(md, [])
  end

  test "remove_capability drops a capability (idempotent)" do
    md = NodeMetadata.new() |> NodeMetadata.add_capability(:storage)

    md = NodeMetadata.remove_capability(md, :storage)
    refute NodeMetadata.has_capability?(md, :storage)

    # Removing an absent capability is a no-op.
    md = NodeMetadata.remove_capability(md, :storage)
    refute NodeMetadata.has_capability?(md, :storage)
  end

  test "tags can be set and read with a default" do
    md = NodeMetadata.new() |> NodeMetadata.put_tag(:zone, "a")

    assert NodeMetadata.get_tag(md, :zone) == "a"
    assert NodeMetadata.get_tag(md, :missing) == nil
    assert NodeMetadata.get_tag(md, :missing, :fallback) == :fallback
  end

  test "resources are merged, not replaced" do
    md =
      NodeMetadata.new(resources: %{cpu: 4})
      |> NodeMetadata.update_resources(%{mem: 16})

    assert md.resources == %{cpu: 4, mem: 16}
  end

  test "to_map/from_map round-trips" do
    md =
      NodeMetadata.new(version: "9.9.9")
      |> NodeMetadata.add_capability(:query)
      |> NodeMetadata.put_tag(:role, "leader")
      |> NodeMetadata.update_resources(%{disk: 100})

    restored = md |> NodeMetadata.to_map() |> NodeMetadata.from_map()

    assert restored == md
  end

  test "from_map accepts string keys" do
    md =
      NodeMetadata.from_map(%{
        "capabilities" => [:a, :b],
        "tags" => %{"k" => "v"},
        "resources" => %{"cpu" => 2},
        "version" => "2.0.0"
      })

    assert NodeMetadata.has_capability?(md, :a)
    assert md.version == "2.0.0"
  end
end
