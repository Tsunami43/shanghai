defmodule Cluster.ValueObjects.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Cluster.ValueObjects.Heartbeat
  alias CoreDomain.Types.NodeId

  doctest Heartbeat

  describe "new/3" do
    test "creates a new heartbeat with default metrics" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1)

      assert heartbeat.node_id == node_id
      assert heartbeat.sequence == 1
      assert heartbeat.metrics == %{}
      assert heartbeat.timestamp != nil
    end

    test "creates a heartbeat with custom metrics" do
      node_id = NodeId.new("node1")
      metrics = %{cpu: 0.5, memory: 0.7}
      heartbeat = Heartbeat.new(node_id, 1, metrics)

      assert heartbeat.metrics == metrics
    end
  end

  describe "fresh?/2" do
    test "returns true for recent heartbeat" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1)

      assert Heartbeat.fresh?(heartbeat, 5000)
    end

    test "returns false for old heartbeat" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1)

      Process.sleep(100)

      refute Heartbeat.fresh?(heartbeat, 50)
    end
  end

  describe "age_ms/1" do
    test "returns age in milliseconds" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1)

      Process.sleep(50)

      age = Heartbeat.age_ms(heartbeat)
      assert age >= 50
      # Upper bound kept generous so scheduling jitter under parallel test load
      # does not make this flaky; it still asserts the heartbeat is recent.
      assert age < 2_000
    end
  end

  describe "with_metrics/2" do
    test "adds metrics to heartbeat" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1)

      updated = Heartbeat.with_metrics(heartbeat, %{cpu: 0.5})

      assert updated.metrics == %{cpu: 0.5}
    end

    test "merges with existing metrics" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1, %{cpu: 0.5})

      updated = Heartbeat.with_metrics(heartbeat, %{memory: 0.7})

      assert updated.metrics == %{cpu: 0.5, memory: 0.7}
    end

    test "overwrites existing keys" do
      node_id = NodeId.new("node1")
      heartbeat = Heartbeat.new(node_id, 1, %{cpu: 0.5})

      updated = Heartbeat.with_metrics(heartbeat, %{cpu: 0.8})

      assert updated.metrics == %{cpu: 0.8}
    end
  end

  describe "newer_than?/2" do
    test "compares by sequence number" do
      node_id = NodeId.new("node1")
      first = Heartbeat.new(node_id, 1)
      second = Heartbeat.new(node_id, 2)

      assert Heartbeat.newer_than?(second, first)
      refute Heartbeat.newer_than?(first, second)
      refute Heartbeat.newer_than?(first, first)
    end
  end

  describe "age_seconds/1" do
    test "returns the age in whole seconds" do
      hb = %{
        Heartbeat.new(NodeId.new("node1"), 1)
        | timestamp: DateTime.add(DateTime.utc_now(), -3, :second)
      }

      assert Heartbeat.age_seconds(hb) >= 3
    end
  end

  describe "latest/2" do
    test "returns the heartbeat with the higher sequence (ties to first)" do
      node_id = NodeId.new("node1")
      first = Heartbeat.new(node_id, 1)
      second = Heartbeat.new(node_id, 2)

      assert Heartbeat.latest(first, second) == second
      assert Heartbeat.latest(second, first) == second
      assert Heartbeat.latest(first, first) == first
    end
  end

  describe "stale?/2" do
    test "is the inverse of fresh?" do
      hb = Heartbeat.new(NodeId.new("node1"), 1)
      refute Heartbeat.stale?(hb, 60_000)

      old = %{hb | timestamp: DateTime.add(DateTime.utc_now(), -100, :second)}
      assert Heartbeat.stale?(old, 1_000)
    end
  end

  describe "metric accessors" do
    test "has_metric?/2 and get_metric/3 read health metrics" do
      hb = Heartbeat.new(NodeId.new("node1"), 1, %{cpu: 0.5})

      assert Heartbeat.has_metric?(hb, :cpu)
      refute Heartbeat.has_metric?(hb, :memory)
      assert Heartbeat.get_metric(hb, :cpu) == 0.5
      assert Heartbeat.get_metric(hb, :memory) == nil
      assert Heartbeat.get_metric(hb, :memory, 0.0) == 0.0
    end
  end

  describe "to_map/1" do
    test "produces a serializable plain map" do
      hb = Heartbeat.new(NodeId.new("node1"), 7, %{cpu: 0.5})

      map = Heartbeat.to_map(hb)
      assert map.node_id == "node1"
      assert map.sequence == 7
      assert map.metrics == %{cpu: 0.5}
      assert %DateTime{} = map.timestamp
    end
  end

  describe "metric_names/1 and metric_count/1" do
    test "list and count the carried metrics" do
      hb = Heartbeat.new(NodeId.new("node1"), 1, %{cpu: 0.5, memory: 0.7})

      assert Heartbeat.metric_names(hb) == [:cpu, :memory]
      assert Heartbeat.metric_count(hb) == 2

      empty = Heartbeat.new(NodeId.new("node2"), 1)
      assert Heartbeat.metric_names(empty) == []
      assert Heartbeat.metric_count(empty) == 0
    end
  end

  describe "from_map/1" do
    test "inverts to_map/1 (round-trip)" do
      hb = Heartbeat.new(NodeId.new("node1"), 7, %{cpu: 0.5})
      restored = hb |> Heartbeat.to_map() |> Heartbeat.from_map()

      assert restored.node_id == hb.node_id
      assert restored.sequence == hb.sequence
      assert restored.timestamp == hb.timestamp
      assert restored.metrics == hb.metrics
    end

    test "defaults metrics to an empty map" do
      map = %{node_id: "n", sequence: 1, timestamp: DateTime.utc_now()}
      assert Heartbeat.from_map(map).metrics == %{}
    end
  end

  describe "next/1" do
    test "advances the sequence and carries metrics forward" do
      hb = Heartbeat.new(NodeId.new("node1"), 4, %{cpu: 0.5})
      nxt = Heartbeat.next(hb)

      assert nxt.node_id == hb.node_id
      assert nxt.sequence == 5
      assert nxt.metrics == %{cpu: 0.5}
      assert Heartbeat.newer_than?(nxt, hb)
    end
  end

  describe "sequence_gap/2" do
    test "counts sequence numbers between two heartbeats" do
      node = NodeId.new("node1")
      a = Heartbeat.new(node, 3)
      b = Heartbeat.new(node, 7)

      assert Heartbeat.sequence_gap(a, b) == 4
      assert Heartbeat.sequence_gap(b, a) == 0
      assert Heartbeat.sequence_gap(a, a) == 0
    end
  end

  describe "describe/1" do
    test "renders a compact description" do
      hb = Heartbeat.new(NodeId.new("n1"), 5)
      assert Heartbeat.describe(hb) == "n1 seq=5"
    end
  end

  describe "put_metric/3" do
    test "sets a single metric" do
      hb = Heartbeat.new(NodeId.new("n1"), 1)
      updated = Heartbeat.put_metric(hb, :cpu, 0.5)

      assert Heartbeat.get_metric(updated, :cpu) == 0.5
      assert Heartbeat.put_metric(updated, :cpu, 0.9) |> Heartbeat.get_metric(:cpu) == 0.9
    end
  end
end
