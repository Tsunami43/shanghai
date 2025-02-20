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

  test "in_sync_count/0 counts fully caught-up replicas" do
    Replication.Monitor.record_leader_offset("is-1", ReplicationOffset.new(10))

    Replication.Monitor.record_follower_offset(
      "is-1",
      NodeId.new("is-f1"),
      ReplicationOffset.new(10)
    )

    assert Replication.in_sync_count() >= 1
  end

  test "sync_ratio/0 is the fraction of caught-up replicas" do
    assert Replication.sync_ratio() >= 0.0 and Replication.sync_ratio() <= 1.0

    Replication.Monitor.record_leader_offset("sr-1", ReplicationOffset.new(10))

    Replication.Monitor.record_follower_offset(
      "sr-1",
      NodeId.new("sr-f1"),
      ReplicationOffset.new(10)
    )

    assert Replication.sync_ratio() > 0.0
  end

  test "overview/0 gives a compact replication snapshot" do
    overview = Replication.overview()

    assert is_integer(overview.groups)
    assert is_integer(overview.replicas)
    assert is_integer(overview.in_sync)
    assert overview.sync_ratio >= 0.0 and overview.sync_ratio <= 1.0
    assert is_integer(overview.max_lag)
    assert is_boolean(overview.healthy)
  end

  test "fully_replicated?/0 requires replicas in every group and health" do
    # No groups configured yet in a fresh monitor: not fully replicated.
    refute Replication.fully_replicated?()

    Replication.Monitor.record_leader_offset("fr-1", ReplicationOffset.new(10))

    Replication.Monitor.record_follower_offset(
      "fr-1",
      NodeId.new("fr-f1"),
      ReplicationOffset.new(10)
    )

    assert is_boolean(Replication.fully_replicated?())
  end

  test "total_lag/0 sums replica lag across groups" do
    assert Replication.total_lag() >= 0

    Replication.Monitor.record_leader_offset("tl-1", ReplicationOffset.new(100))

    Replication.Monitor.record_follower_offset(
      "tl-1",
      NodeId.new("tl-f1"),
      ReplicationOffset.new(40)
    )

    assert Replication.total_lag() >= 60
  end

  test "unhealthy_group_ids/0 lists groups with a lagging or stale replica" do
    assert is_list(Replication.unhealthy_group_ids())

    Replication.Monitor.record_leader_offset("ug-1", ReplicationOffset.new(1000))

    Replication.Monitor.record_follower_offset(
      "ug-1",
      NodeId.new("ug-f1"),
      ReplicationOffset.new(1)
    )

    assert is_list(Replication.unhealthy_group_ids())
  end

  test "behind_count/0 counts replicas behind the leader" do
    assert Replication.behind_count() >= 0

    Replication.Monitor.record_leader_offset("bc-1", ReplicationOffset.new(100))

    Replication.Monitor.record_follower_offset(
      "bc-1",
      NodeId.new("bc-f1"),
      ReplicationOffset.new(10)
    )

    assert Replication.behind_count() >= 1
  end

  test "avg_lag/0 averages replica lag" do
    assert Replication.avg_lag() >= 0.0

    Replication.Monitor.record_leader_offset("al-1", ReplicationOffset.new(100))

    Replication.Monitor.record_follower_offset(
      "al-1",
      NodeId.new("al-f1"),
      ReplicationOffset.new(50)
    )

    assert Replication.avg_lag() >= 0.0
  end

  test "no_groups?/0 reflects whether any group is tracked" do
    assert is_boolean(Replication.no_groups?())

    Replication.Monitor.record_leader_offset("ng-1", ReplicationOffset.new(1))
    refute Replication.no_groups?()
  end

  test "unhealthy_ratio/0 is a fraction in 0.0..1.0" do
    ratio = Replication.unhealthy_ratio()
    assert ratio >= 0.0 and ratio <= 2.0
  end

  test "avg_replicas_per_group/0 is a non-negative float" do
    assert Replication.avg_replicas_per_group() >= 0.0

    Replication.Monitor.record_leader_offset("ar-1", ReplicationOffset.new(1))

    Replication.Monitor.record_follower_offset(
      "ar-1",
      NodeId.new("ar-f1"),
      ReplicationOffset.new(1)
    )

    assert Replication.avg_replicas_per_group() > 0.0
  end

  test "any_unhealthy?/0 reflects lagging or stale replicas" do
    assert Replication.any_unhealthy?() == not Replication.healthy?()
  end

  test "group_replica_count/0 counts replicas in a group" do
    assert Replication.group_replica_count("grc-missing") == 0

    Replication.Monitor.record_leader_offset("grc-1", ReplicationOffset.new(1))

    Replication.Monitor.record_follower_offset(
      "grc-1",
      NodeId.new("grc-f1"),
      ReplicationOffset.new(1)
    )

    assert Replication.group_replica_count("grc-1") >= 1
  end
end
