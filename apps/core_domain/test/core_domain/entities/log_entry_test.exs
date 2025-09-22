defmodule CoreDomain.Entities.LogEntryTest do
  use ExUnit.Case, async: true

  alias CoreDomain.Entities.LogEntry
  alias CoreDomain.Types.{LogSequenceNumber, NodeId}

  defp entry(lsn_value) do
    LogEntry.new(LogSequenceNumber.new(lsn_value), "payload", %NodeId{value: "node-1"}, %{})
  end

  test "new/4 populates all fields and stamps a timestamp" do
    lsn = LogSequenceNumber.new(5)
    node_id = %NodeId{value: "node-9"}
    entry = LogEntry.new(lsn, %{k: :v}, node_id, %{origin: :test})

    assert entry.lsn == lsn
    assert entry.data == %{k: :v}
    assert entry.node_id == node_id
    assert entry.metadata == %{origin: :test}
    assert %DateTime{} = entry.timestamp
  end

  test "new/3 defaults metadata to an empty map" do
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", %NodeId{value: "n"})
    assert entry.metadata == %{}
  end

  test "compare/2 orders entries by LSN" do
    assert LogEntry.compare(entry(1), entry(2)) == :lt
    assert LogEntry.compare(entry(2), entry(1)) == :gt
    assert LogEntry.compare(entry(3), entry(3)) == :eq
  end

  test "newer_than?/2 and older_than?/2 follow the LSN order" do
    assert LogEntry.newer_than?(entry(2), entry(1))
    refute LogEntry.newer_than?(entry(1), entry(2))
    refute LogEntry.newer_than?(entry(3), entry(3))

    assert LogEntry.older_than?(entry(1), entry(2))
    refute LogEntry.older_than?(entry(2), entry(1))
    refute LogEntry.older_than?(entry(3), entry(3))
  end

  test "same_lsn?/2 is true only for equal LSNs" do
    assert LogEntry.same_lsn?(entry(4), entry(4))
    refute LogEntry.same_lsn?(entry(4), entry(5))
  end

  test "latest/2 returns the entry with the higher LSN" do
    a = entry(3)
    b = entry(7)
    assert LogEntry.latest(a, b) == b
    assert LogEntry.latest(b, a) == b
  end

  test "metadata_empty?/1 reflects whether metadata is set" do
    id = %NodeId{value: "n"}
    assert LogEntry.metadata_empty?(LogEntry.new(LogSequenceNumber.new(1), "d", id))
    refute LogEntry.metadata_empty?(LogEntry.new(LogSequenceNumber.new(1), "d", id, %{a: 1}))
  end

  test "earliest/2 returns the entry with the lower LSN" do
    a = entry(3)
    b = entry(7)
    assert LogEntry.earliest(a, b) == a
    assert LogEntry.earliest(b, a) == a
  end

  test "lsn_value/1 returns the raw integer LSN" do
    id = %NodeId{value: "n"}
    assert LogEntry.lsn_value(LogEntry.new(LogSequenceNumber.new(42), "d", id)) == 42
  end

  test "get_metadata/3 reads a key or the default" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{source: "leader"})
    assert LogEntry.get_metadata(entry, :source) == "leader"
    assert LogEntry.get_metadata(entry, :missing) == nil
    assert LogEntry.get_metadata(entry, :missing, :fallback) == :fallback
  end

  test "put_metadata/3 sets a metadata key" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id)
    updated = LogEntry.put_metadata(entry, :source, "follower")
    assert LogEntry.get_metadata(updated, :source) == "follower"
    refute LogEntry.metadata_empty?(updated)
  end

  test "to_map/1 produces a serializable plain map" do
    id = %NodeId{value: "node-7"}
    entry = LogEntry.new(LogSequenceNumber.new(42), "payload", id, %{source: "leader"})

    map = LogEntry.to_map(entry)
    assert map.lsn == 42
    assert map.data == "payload"
    assert map.node_id == "node-7"
    assert map.metadata == %{source: "leader"}
    assert %DateTime{} = map.timestamp
  end

  test "age_ms/1 and age_seconds/1 measure elapsed time since the timestamp" do
    id = %NodeId{value: "n"}

    entry = %{
      LogEntry.new(LogSequenceNumber.new(1), "d", id)
      | timestamp: DateTime.add(DateTime.utc_now(), -3, :second)
    }

    assert LogEntry.age_ms(entry) >= 3_000
    assert LogEntry.age_seconds(entry) >= 3
  end

  test "from_map/1 inverts to_map/1 (round-trip)" do
    id = NodeId.new("node-7")
    entry = LogEntry.new(LogSequenceNumber.new(42), "payload", id, %{source: "leader"})

    restored = entry |> LogEntry.to_map() |> LogEntry.from_map()

    assert restored.lsn == entry.lsn
    assert restored.data == entry.data
    assert restored.node_id == entry.node_id
    assert restored.metadata == entry.metadata
    assert restored.timestamp == entry.timestamp
  end

  test "from_map/1 defaults metadata to an empty map" do
    map = %{lsn: 1, data: "d", timestamp: DateTime.utc_now(), node_id: "n"}
    assert LogEntry.from_map(map).metadata == %{}
  end

  test "same_node?/2 and from_node?/2 compare producing nodes" do
    a = %NodeId{value: "n1"}
    b = %NodeId{value: "n2"}

    e1 = LogEntry.new(LogSequenceNumber.new(1), "d", a)
    e2 = LogEntry.new(LogSequenceNumber.new(2), "d", a)
    e3 = LogEntry.new(LogSequenceNumber.new(3), "d", b)

    assert LogEntry.same_node?(e1, e2)
    refute LogEntry.same_node?(e1, e3)
    assert LogEntry.from_node?(e1, a)
    refute LogEntry.from_node?(e1, b)
  end

  test "describe/1 renders a compact description" do
    id = %NodeId{value: "n1"}
    entry = LogEntry.new(LogSequenceNumber.new(7), "d", id)
    assert LogEntry.describe(entry) == "LSN(7) from n1"
  end

  test "has_metadata?/2 checks for a metadata key" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{source: "leader"})

    assert LogEntry.has_metadata?(entry, :source)
    refute LogEntry.has_metadata?(entry, :missing)
  end

  test "metadata_keys/1 returns sorted keys" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{b: 2, a: 1})

    assert LogEntry.metadata_keys(entry) == [:a, :b]
    assert LogEntry.metadata_keys(LogEntry.new(LogSequenceNumber.new(1), "d", id)) == []
  end

  test "delete_metadata/2 removes a metadata key" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{a: 1, b: 2})

    updated = LogEntry.delete_metadata(entry, :a)
    assert LogEntry.get_metadata(updated, :a) == nil
    assert LogEntry.get_metadata(updated, :b) == 2
  end

  test "merge_metadata/2 merges fields into metadata" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{a: 1})

    updated = LogEntry.merge_metadata(entry, %{a: 9, b: 2})
    assert LogEntry.get_metadata(updated, :a) == 9
    assert LogEntry.get_metadata(updated, :b) == 2
  end

  test "sort/1 orders entries by ascending LSN" do
    id = %NodeId{value: "n"}
    a = LogEntry.new(LogSequenceNumber.new(3), "c", id)
    b = LogEntry.new(LogSequenceNumber.new(1), "a", id)
    c = LogEntry.new(LogSequenceNumber.new(2), "b", id)

    sorted = LogEntry.sort([a, b, c])
    assert Enum.map(sorted, &LogEntry.lsn_value/1) == [1, 2, 3]
  end

  test "contiguous?/1 detects LSN gaps in a sequence" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    assert LogEntry.contiguous?([entry.(1), entry.(2), entry.(3)])
    refute LogEntry.contiguous?([entry.(1), entry.(3)])
    assert LogEntry.contiguous?([entry.(5)])
    assert LogEntry.contiguous?([])
  end

  test "from_node/2 filters entries by producing node" do
    a = %NodeId{value: "a"}
    b = %NodeId{value: "b"}
    entry = fn n, id -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(1, a), entry.(2, b), entry.(3, a)]
    from_a = LogEntry.from_node(entries, a)

    assert length(from_a) == 2
    assert Enum.all?(from_a, &(&1.node_id == a))
  end

  test "node_ids/1 returns distinct sorted producing nodes" do
    a = %NodeId{value: "a"}
    b = %NodeId{value: "b"}
    entry = fn n, id -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(1, b), entry.(2, a), entry.(3, b)]
    assert Enum.map(LogEntry.node_ids(entries), & &1.value) == ["a", "b"]
  end

  test "in_lsn_range/3 filters entries by LSN window" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(1), entry.(2), entry.(3), entry.(4)]
    windowed = LogEntry.in_lsn_range(entries, LogSequenceNumber.new(2), LogSequenceNumber.new(3))

    assert Enum.map(windowed, &LogEntry.lsn_value/1) == [2, 3]
  end

  test "max_by_lsn/1 and min_by_lsn/1 pick the extreme entries" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(3), entry.(1), entry.(7), entry.(2)]
    assert LogEntry.lsn_value(LogEntry.max_by_lsn(entries)) == 7
    assert LogEntry.lsn_value(LogEntry.min_by_lsn(entries)) == 1
  end

  test "node_id_value/1 returns the producing node id string" do
    id = %NodeId{value: "node-7"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id)
    assert LogEntry.node_id_value(entry) == "node-7"
  end

  test "sort_desc/1 orders entries by descending LSN" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    sorted = LogEntry.sort_desc([entry.(1), entry.(3), entry.(2)])
    assert Enum.map(sorted, &LogEntry.lsn_value/1) == [3, 2, 1]
  end

  test "latest_of/1 and earliest_of/1 reduce a list to the extreme entry" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(3), entry.(1), entry.(7), entry.(2)]
    assert LogEntry.lsn_value(LogEntry.latest_of(entries)) == 7
    assert LogEntry.lsn_value(LogEntry.earliest_of(entries)) == 1
  end

  test "with_lsn/2 filters entries by exact LSN" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    entries = [entry.(1), entry.(2), entry.(2), entry.(3)]
    matched = LogEntry.with_lsn(entries, LogSequenceNumber.new(2))

    assert length(matched) == 2
    assert Enum.all?(matched, &(LogEntry.lsn_value(&1) == 2))
  end

  test "group_by_node/1 groups entries by producing node" do
    a = %NodeId{value: "a"}
    b = %NodeId{value: "b"}
    entry = fn n, id -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    grouped = LogEntry.group_by_node([entry.(1, a), entry.(2, b), entry.(3, a)])

    assert length(grouped[a]) == 2
    assert length(grouped[b]) == 1
  end

  test "metadata_count/1 counts metadata entries" do
    id = %NodeId{value: "n"}
    entry = LogEntry.new(LogSequenceNumber.new(1), "d", id, %{a: 1, b: 2})

    assert LogEntry.metadata_count(entry) == 2
    assert LogEntry.metadata_count(LogEntry.new(LogSequenceNumber.new(1), "d", id)) == 0
  end

  test "ordered?/1 checks ascending LSN order" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    assert LogEntry.ordered?([entry.(1), entry.(2), entry.(2), entry.(5)])
    refute LogEntry.ordered?([entry.(2), entry.(1)])
    assert LogEntry.ordered?([entry.(3)])
    assert LogEntry.ordered?([])
  end

  test "gaps/1 reports LSN jumps in an ordered list" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    assert LogEntry.gaps([entry.(1), entry.(2), entry.(5), entry.(6)]) == [{2, 5}]
    assert LogEntry.gaps([entry.(1), entry.(2), entry.(3)]) == []
  end

  test "first_gap/1 returns the earliest gap or nil" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    assert LogEntry.first_gap([entry.(1), entry.(3), entry.(9)]) == {1, 3}
    assert LogEntry.first_gap([entry.(1), entry.(2)]) == nil
  end

  test "lsn_span/1 returns the min and max LSN integers" do
    id = %NodeId{value: "n"}
    entry = fn n -> LogEntry.new(LogSequenceNumber.new(n), "d", id) end

    assert LogEntry.lsn_span([entry.(3), entry.(1), entry.(7)]) == {1, 7}
  end

  describe "metadata/1 and take_metadata/2" do
    test "return and filter the metadata map" do
      entry =
        LogEntry.new(LogSequenceNumber.new(1), "payload", NodeId.new("n1"))
        |> LogEntry.merge_metadata(%{a: 1, b: 2, c: 3})

      assert LogEntry.metadata(entry) == %{a: 1, b: 2, c: 3}
      assert LogEntry.metadata(LogEntry.take_metadata(entry, [:a, :c])) == %{a: 1, c: 3}
      assert LogEntry.metadata(LogEntry.take_metadata(entry, [])) == %{}
    end
  end

  describe "drop_metadata/2" do
    test "removes the given metadata keys" do
      entry =
        LogEntry.new(LogSequenceNumber.new(1), "payload", NodeId.new("n1"))
        |> LogEntry.merge_metadata(%{a: 1, b: 2, c: 3})

      assert LogEntry.metadata(LogEntry.drop_metadata(entry, [:b])) == %{a: 1, c: 3}
      assert LogEntry.metadata(LogEntry.drop_metadata(entry, [:a, :b, :c])) == %{}
      assert LogEntry.metadata(LogEntry.drop_metadata(entry, [])) == %{a: 1, b: 2, c: 3}
    end
  end
end
