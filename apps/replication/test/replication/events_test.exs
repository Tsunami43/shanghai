defmodule Replication.EventsTest do
  @moduledoc "Replication event structs and their Event protocol implementations."

  use ExUnit.Case, async: true

  alias CoreDomain.Protocols.Event
  alias CoreDomain.Types.NodeId
  alias Replication.Events.{LeaderElected, ReplicaCaughtUp, ReplicaFellBehind}
  alias Replication.ValueObjects.ReplicationOffset

  test "LeaderElected carries the leader/term and implements Event" do
    leader = NodeId.new("node-1")
    event = LeaderElected.new("group-a", leader, 7, %{via: :election})

    assert event.group_id == "group-a"
    assert event.leader_node_id == leader
    assert event.term == 7
    assert Event.event_type(event) == :leader_elected
    assert Event.metadata(event) == %{via: :election}
    assert %DateTime{} = Event.timestamp(event)
  end

  test "ReplicaFellBehind computes the lag and implements Event" do
    replica = NodeId.new("node-2")

    event =
      ReplicaFellBehind.new(
        "group-a",
        replica,
        ReplicationOffset.new(4),
        ReplicationOffset.new(10)
      )

    assert event.replica_node_id == replica
    assert event.lag == 6
    assert Event.event_type(event) == :replica_fell_behind
  end

  test "ReplicaCaughtUp records the offset and implements Event" do
    replica = NodeId.new("node-3")
    event = ReplicaCaughtUp.new("group-a", replica, ReplicationOffset.new(10))

    assert event.replica_node_id == replica
    assert event.offset == ReplicationOffset.new(10)
    assert Event.event_type(event) == :replica_caught_up
  end
end
