defmodule Cluster.EventsTest do
  @moduledoc "Membership event structs and their Event protocol implementations."

  use ExUnit.Case, async: true

  alias Cluster.Entities.Node
  alias Cluster.Events.{NodeDetectedDown, NodeJoined, NodeLeft}
  alias CoreDomain.Protocols.Event
  alias CoreDomain.Types.NodeId

  test "NodeJoined carries the node and implements Event" do
    node = Node.new(NodeId.new("n1"), "localhost", 4000)
    event = NodeJoined.new(node, %{source: :test})

    assert event.node == node
    assert event.node_id == node.id
    assert Event.event_type(event) == :node_joined
    assert Event.metadata(event) == %{source: :test}
    assert %DateTime{} = Event.timestamp(event)
  end

  test "NodeLeft records the reason and implements Event" do
    id = NodeId.new("n2")
    event = NodeLeft.new(id, :crashed, %{via: :monitor})

    assert event.node_id == id
    assert event.reason == :crashed
    assert Event.event_type(event) == :node_left
    assert Event.metadata(event) == %{via: :monitor}
  end

  test "NodeLeft defaults the reason to :graceful" do
    assert NodeLeft.new(NodeId.new("n3")).reason == :graceful
  end

  test "NodeDetectedDown records the detection method and implements Event" do
    id = NodeId.new("n4")
    event = NodeDetectedDown.new(id, :phi_accrual)

    assert event.node_id == id
    assert event.detection_method == :phi_accrual
    assert Event.event_type(event) == :node_detected_down
  end

  test "NodeDetectedDown defaults the method to :heartbeat_failure" do
    assert NodeDetectedDown.new(NodeId.new("n5")).detection_method == :heartbeat_failure
  end
end
