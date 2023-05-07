defmodule Replication.MonitorTelemetryTest do
  @moduledoc "The Monitor emits replication-lag telemetry (observable by default)."

  use ExUnit.Case, async: false

  alias CoreDomain.Types.NodeId
  alias Replication.Monitor
  alias Replication.ValueObjects.ReplicationOffset

  @event [:shanghai, :replication, :lag]

  setup do
    start_supervised!({Monitor, [lag_threshold: 5, check_interval_ms: 500]})

    handler_id = "repl-lag-telemetry-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "recording a follower offset emits a lag measurement" do
    group_id = "tel-group"
    Monitor.record_leader_offset(group_id, ReplicationOffset.new(10))
    Monitor.record_follower_offset(group_id, NodeId.new("follower1"), ReplicationOffset.new(4))

    assert_receive {:telemetry, @event, measurements, metadata}
    assert measurements.offset_lag == 6
    assert metadata.group_id == group_id
    assert metadata.follower_id == NodeId.new("follower1")
  end
end
