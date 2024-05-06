defmodule Replication.SummaryTest do
  @moduledoc "Replication.summary/0 aggregates group and replica counts."

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Monitor
  alias Replication.ValueObjects.ReplicationOffset

  setup do
    start_supervised!({Monitor, [lag_threshold: 5, check_interval_ms: 500]})
    :ok
  end

  test "counts groups and tracked replicas" do
    empty = Replication.summary()
    assert empty.groups == 0
    assert empty.replicas == 0

    Monitor.record_leader_offset("g1", ReplicationOffset.new(10))
    Monitor.record_follower_offset("g1", NodeId.new("f1"), ReplicationOffset.new(9))
    Monitor.record_follower_offset("g1", NodeId.new("f2"), ReplicationOffset.new(8))
    Monitor.record_leader_offset("g2", ReplicationOffset.new(4))
    Monitor.record_follower_offset("g2", NodeId.new("f3"), ReplicationOffset.new(4))

    summary = Replication.summary()
    assert summary.groups == 2
    assert summary.replicas == 3
    assert is_integer(summary.lagging)
    assert is_integer(summary.stale)
    assert is_boolean(summary.healthy)
    assert is_integer(summary.max_lag)
    assert summary.max_lag >= 0
  end

  test "replica_count/0 counts tracked replicas across groups" do
    Monitor.record_leader_offset("rc1", ReplicationOffset.new(10))
    Monitor.record_follower_offset("rc1", NodeId.new("rc-f1"), ReplicationOffset.new(9))
    Monitor.record_follower_offset("rc1", NodeId.new("rc-f2"), ReplicationOffset.new(8))

    assert Replication.replica_count() >= 2
  end

  test "group_count/0 counts replication groups" do
    Monitor.record_leader_offset("gc1", ReplicationOffset.new(5))
    Monitor.record_leader_offset("gc2", ReplicationOffset.new(5))

    assert Replication.group_count() >= 2
  end

  test "healthy?/0 is true with no lagging or stale replicas" do
    assert is_boolean(Replication.healthy?())

    assert Replication.healthy?() ==
             (Replication.summary().lagging == 0 and
                Replication.summary().stale == 0)
  end

  test "lagging_count/0 and stale_count/0 agree with the summary" do
    Monitor.record_leader_offset("lc1", ReplicationOffset.new(100))
    Monitor.record_follower_offset("lc1", NodeId.new("lc-f1"), ReplicationOffset.new(1))

    summary = Replication.summary()
    assert Replication.lagging_count() == summary.lagging
    assert Replication.stale_count() == summary.stale
  end

  test "group_ids/0 lists group ids sorted" do
    Monitor.record_leader_offset("gid-b", ReplicationOffset.new(1))
    Monitor.record_leader_offset("gid-a", ReplicationOffset.new(1))

    ids = Replication.group_ids()
    assert "gid-a" in ids
    assert "gid-b" in ids
    assert ids == Enum.sort(ids)
  end

  test "has_group?/1 reflects whether a group is tracked" do
    refute Replication.has_group?("hg-missing")

    Monitor.record_leader_offset("hg-1", ReplicationOffset.new(1))
    assert Replication.has_group?("hg-1")
  end

  test "max_lag/0 returns the worst replica lag across groups" do
    assert Replication.max_lag() >= 0

    Replication.Monitor.record_leader_offset("ml-1", ReplicationOffset.new(100))

    Replication.Monitor.record_follower_offset(
      "ml-1",
      NodeId.new("ml-f1"),
      ReplicationOffset.new(10)
    )

    assert Replication.max_lag() >= 90
  end
end
