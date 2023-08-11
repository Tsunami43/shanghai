defmodule Cluster.ValueObjects.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Cluster.ValueObjects.Heartbeat
  alias CoreDomain.Types.NodeId

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
      assert age < 200
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
end
