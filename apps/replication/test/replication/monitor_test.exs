defmodule Replication.MonitorTest do
  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Monitor
  alias Replication.ValueObjects.ReplicationOffset

  setup do
    # Start monitor with short intervals for testing
    start_supervised!(
      {Monitor, [lag_threshold: 5, stale_threshold_ms: 1000, check_interval_ms: 500]}
    )

    :ok
  end

  describe "Offset tracking" do
    test "records leader offset" do
      group_id = "test-group"
      offset = ReplicationOffset.new(10)

      Monitor.record_leader_offset(group_id, offset)

      Process.sleep(50)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert metrics.leader_offset.value == 10
    end

    test "records follower offset" do
      group_id = "test-group"
      follower_id = NodeId.new("follower1")
      offset = ReplicationOffset.new(5)

      Monitor.record_follower_offset(group_id, follower_id, offset)

      Process.sleep(50)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert Map.has_key?(metrics.replicas, follower_id)
      assert metrics.replicas[follower_id].offset.value == 5
    end

    test "calculates lag for followers" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(10)
      follower_id = NodeId.new("follower1")
      follower_offset = ReplicationOffset.new(5)

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower_id, follower_offset)

      Process.sleep(50)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert metrics.replicas[follower_id].lag == 5
    end
  end

  describe "Health detection" do
    test "marks follower as healthy when caught up" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(10)
      follower_id = NodeId.new("follower1")
      follower_offset = ReplicationOffset.new(9)

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower_id, follower_offset)

      Process.sleep(50)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert metrics.replicas[follower_id].status == :healthy
    end

    test "marks follower as lagging when behind threshold" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(20)
      follower_id = NodeId.new("follower1")
      follower_offset = ReplicationOffset.new(10)

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower_id, follower_offset)

      Process.sleep(50)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert metrics.replicas[follower_id].status == :lagging
    end

    test "marks follower as stale when no updates" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(10)
      follower_id = NodeId.new("follower1")
      follower_offset = ReplicationOffset.new(5)

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower_id, follower_offset)

      # Wait for stale threshold (1000ms) + health check (500ms)
      Process.sleep(1600)

      {:ok, metrics} = Monitor.get_group_metrics(group_id)
      assert metrics.replicas[follower_id].status == :stale
    end
  end

  describe "Querying metrics" do
    test "returns error for unknown group" do
      result = Monitor.get_group_metrics("unknown-group")
      assert result == {:error, :not_found}
    end

    test "returns all lagging replicas" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(20)
      follower1_id = NodeId.new("follower1")
      follower2_id = NodeId.new("follower2")

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower1_id, ReplicationOffset.new(5))
      Monitor.record_follower_offset(group_id, follower2_id, ReplicationOffset.new(18))

      Process.sleep(50)

      lagging = Monitor.get_lagging_replicas()
      assert length(lagging) == 1
      assert Enum.any?(lagging, &(&1.node_id == follower1_id))
    end

    test "returns all stale replicas" do
      group_id = "test-group"
      leader_offset = ReplicationOffset.new(20)
      follower_id = NodeId.new("follower1")

      Monitor.record_leader_offset(group_id, leader_offset)
      Monitor.record_follower_offset(group_id, follower_id, ReplicationOffset.new(15))

      # Wait for stale threshold + health check
      Process.sleep(1600)

      stale = Monitor.get_stale_replicas()
      assert length(stale) == 1
      assert Enum.any?(stale, &(&1.node_id == follower_id))
    end
  end

  describe "Multiple groups" do
    test "tracks metrics for multiple groups independently" do
      group1 = "group-1"
      group2 = "group-2"

      Monitor.record_leader_offset(group1, ReplicationOffset.new(10))
      Monitor.record_leader_offset(group2, ReplicationOffset.new(20))

      Process.sleep(50)

      {:ok, metrics1} = Monitor.get_group_metrics(group1)
      {:ok, metrics2} = Monitor.get_group_metrics(group2)

      assert metrics1.leader_offset.value == 10
      assert metrics2.leader_offset.value == 20
    end
  end
end
