defmodule CoreDomain.Types.NodeIdTest do
  use ExUnit.Case, async: true

  alias CoreDomain.Types.NodeId

  doctest NodeId

  test "new/1 wraps a string value" do
    assert NodeId.new("node-1").value == "node-1"
  end

  test "generate/0 produces distinct 32-char hex ids" do
    a = NodeId.generate()
    b = NodeId.generate()

    assert String.length(a.value) == 32
    assert a.value =~ ~r/\A[0-9a-f]{32}\z/
    refute NodeId.equal?(a, b)
  end

  test "equal?/2 compares by value" do
    assert NodeId.equal?(NodeId.new("n"), NodeId.new("n"))
    refute NodeId.equal?(NodeId.new("n1"), NodeId.new("n2"))
  end

  test "to_string/1 returns the underlying value" do
    assert NodeId.to_string(NodeId.new("node-9")) == "node-9"
  end

  test "starts_with?/2 checks the id prefix" do
    assert NodeId.starts_with?(NodeId.new("node-1"), "node")
    refute NodeId.starts_with?(NodeId.new("node-1"), "x")
  end

  test "compare/2 orders by string value" do
    assert NodeId.compare(NodeId.new("a"), NodeId.new("b")) == :lt
    assert NodeId.compare(NodeId.new("b"), NodeId.new("a")) == :gt
    assert NodeId.compare(NodeId.new("a"), NodeId.new("a")) == :eq
  end

  test "short/2 truncates long ids and leaves short ones intact" do
    assert NodeId.short(NodeId.new("abcdef0123456789"), 6) == "abcdef"
    assert NodeId.short(NodeId.new("abc"), 6) == "abc"
    assert String.length(NodeId.short(NodeId.generate())) == 8
  end

  test "valid?/1 accepts non-empty binaries and rejects others" do
    assert NodeId.valid?("node-1")
    refute NodeId.valid?("")
    refute NodeId.valid?(nil)
    refute NodeId.valid?(123)
  end

  test "hash/1 is deterministic and non-negative" do
    assert NodeId.hash(NodeId.new("n1")) == NodeId.hash(NodeId.new("n1"))
    assert NodeId.hash(NodeId.new("n1")) >= 0
  end

  test "slot/2 maps into the requested range" do
    for i <- 1..50 do
      slot = NodeId.slot(NodeId.new("node-#{i}"), 16)
      assert slot >= 0 and slot < 16
    end

    assert NodeId.slot(NodeId.new("n1"), 8) == NodeId.slot(NodeId.new("n1"), 8)
  end

  test "sort/1 orders node ids by value" do
    ids = [NodeId.new("c"), NodeId.new("a"), NodeId.new("b")]
    assert Enum.map(NodeId.sort(ids), & &1.value) == ["a", "b", "c"]
    assert NodeId.sort([]) == []
  end

  test "uniq/1 deduplicates by value, keeping order" do
    ids = [NodeId.new("a"), NodeId.new("b"), NodeId.new("a"), NodeId.new("c")]
    assert Enum.map(NodeId.uniq(ids), & &1.value) == ["a", "b", "c"]
    assert NodeId.uniq([]) == []
  end

  test "contains?/2 checks for a substring" do
    assert NodeId.contains?(NodeId.new("node-eu-1"), "eu")
    refute NodeId.contains?(NodeId.new("node-eu-1"), "us")
  end

  test "from_erlang_node/1 extracts the id before the @" do
    assert NodeId.from_erlang_node(:n1@localhost).value == "n1"
    assert NodeId.from_erlang_node("n2@host").value == "n2"
    assert NodeId.from_erlang_node("plain").value == "plain"
  end

  test "ends_with?/2 checks the id suffix" do
    assert NodeId.ends_with?(NodeId.new("node-eu-1"), "1")
    refute NodeId.ends_with?(NodeId.new("node-eu-1"), "2")
  end

  test "length/1 returns the value length" do
    assert NodeId.length(NodeId.new("node1")) == 5
    assert NodeId.length(NodeId.new("")) == 0
  end

  test "differ?/2 is the inverse of equal?/2" do
    refute NodeId.differ?(NodeId.new("n"), NodeId.new("n"))
    assert NodeId.differ?(NodeId.new("n1"), NodeId.new("n2"))
  end

  test "blank?/1 detects an empty id" do
    assert NodeId.blank?(NodeId.new(""))
    refute NodeId.blank?(NodeId.new("n1"))
  end
end
