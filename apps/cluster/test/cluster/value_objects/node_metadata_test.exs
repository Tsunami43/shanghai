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

  test "merge/2 unions capabilities and merges tags/resources" do
    left =
      NodeMetadata.new()
      |> NodeMetadata.add_capability(:storage)
      |> NodeMetadata.put_tag(:region, "eu")

    right =
      NodeMetadata.new(version: "2.0.0")
      |> NodeMetadata.add_capability(:query)
      |> NodeMetadata.put_tag(:region, "us")
      |> NodeMetadata.update_resources(%{cpu: 8})

    merged = NodeMetadata.merge(left, right)

    assert NodeMetadata.capabilities(merged) == [:query, :storage]
    assert NodeMetadata.get_tag(merged, :region) == "us"
    assert NodeMetadata.get_resource(merged, :cpu) == 8
    assert merged.version == "2.0.0"
  end

  test "resource_keys/1 returns sorted keys" do
    md = NodeMetadata.new() |> NodeMetadata.update_resources(%{mem: 16, cpu: 8})
    assert NodeMetadata.resource_keys(md) == [:cpu, :mem]
    assert NodeMetadata.resource_keys(NodeMetadata.new()) == []
  end

  test "get_resource/3 reads a resource or the default" do
    md = NodeMetadata.new() |> NodeMetadata.update_resources(%{cpu: 8})
    assert NodeMetadata.get_resource(md, :cpu) == 8
    assert NodeMetadata.get_resource(md, :mem, 0) == 0
  end

  test "delete_tag/2 removes a tag (idempotent)" do
    md = NodeMetadata.new() |> NodeMetadata.put_tag(:region, "eu")
    md = NodeMetadata.delete_tag(md, :region)
    refute NodeMetadata.has_tag?(md, :region)
    assert NodeMetadata.delete_tag(md, :region) == md
  end

  test "tag_keys/1 returns sorted tag keys" do
    md =
      NodeMetadata.new()
      |> NodeMetadata.put_tag(:zone, "a")
      |> NodeMetadata.put_tag(:region, "eu")

    assert NodeMetadata.tag_keys(md) == [:region, :zone]
    assert NodeMetadata.tag_keys(NodeMetadata.new()) == []
  end

  test "has_tag?/2 reflects whether a tag is set" do
    md = NodeMetadata.new() |> NodeMetadata.put_tag(:region, "eu")
    assert NodeMetadata.has_tag?(md, :region)
    refute NodeMetadata.has_tag?(md, :zone)
  end

  test "tag_count/1 counts the tags" do
    md =
      NodeMetadata.new()
      |> NodeMetadata.put_tag(:region, "eu")
      |> NodeMetadata.put_tag(:zone, "a")

    assert NodeMetadata.tag_count(md) == 2
    assert NodeMetadata.tag_count(NodeMetadata.new()) == 0
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

  test "capability_count/1 counts advertised capabilities" do
    md =
      NodeMetadata.new()
      |> NodeMetadata.add_capability(:storage)
      |> NodeMetadata.add_capability(:query)

    assert NodeMetadata.capability_count(md) == 2
    assert NodeMetadata.capability_count(NodeMetadata.new()) == 0
  end

  test "empty?/1 is true only with no capabilities, tags, or resources" do
    assert NodeMetadata.empty?(NodeMetadata.new())
    assert NodeMetadata.empty?(NodeMetadata.new(version: "9.9.9"))

    refute NodeMetadata.empty?(NodeMetadata.new() |> NodeMetadata.add_capability(:storage))
    refute NodeMetadata.empty?(NodeMetadata.new() |> NodeMetadata.put_tag(:region, "eu"))
    refute NodeMetadata.empty?(NodeMetadata.new() |> NodeMetadata.update_resources(%{cpu: 1}))
  end
end
