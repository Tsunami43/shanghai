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
  end

  test "healthy?/0 is true with no lagging or stale replicas" do
    assert is_boolean(Replication.healthy?())
    assert Replication.healthy?() == (Replication.summary().lagging == 0 and
                                        Replication.summary().stale == 0)
  end
end
