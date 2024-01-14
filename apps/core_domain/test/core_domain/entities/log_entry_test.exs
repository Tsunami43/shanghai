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
end
