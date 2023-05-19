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
end
