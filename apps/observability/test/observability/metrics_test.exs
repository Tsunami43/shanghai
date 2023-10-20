defmodule Observability.MetricsTest do
  @moduledoc "Smoke tests: every emitter fires its declared telemetry event."

  use ExUnit.Case, async: true

  alias Observability.Metrics

  setup do
    handler = "metrics-test-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      Metrics.event_names(),
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "wal_write_completed emits a write event" do
    Metrics.wal_write_completed(1.5, 128, 1)
    assert_receive {:telemetry, [:shanghai, :storage, :wal, :write], m, %{segment_id: 1}}
    assert m.duration == 1.5 and m.bytes == 128
  end

  test "wal_sync_completed emits a sync event" do
    Metrics.wal_sync_completed(0.5, 2)
    assert_receive {:telemetry, [:shanghai, :storage, :wal, :sync], %{duration: 0.5}, _}
  end

  test "replication_lag_measured emits a lag event" do
    Metrics.replication_lag_measured(6, 12, "g", "f", "l")
    assert_receive {:telemetry, [:shanghai, :replication, :lag], %{offset_lag: 6}, _}
  end

  test "heartbeat_completed emits a heartbeat event" do
    Metrics.heartbeat_completed(3, "a", "b")
    assert_receive {:telemetry, [:shanghai, :cluster, :heartbeat], %{rtt_ms: 3}, _}
  end

  test "cluster_membership_changed emits a membership event" do
    Metrics.cluster_membership_changed(4, :node_joined, "n1")
    assert_receive {:telemetry, [:shanghai, :cluster, :membership_change], %{node_count: 4}, _}
  end

  test "compaction_completed emits a compaction event" do
    Metrics.compaction_completed(10, 100, 40, ["s"])
    assert_receive {:telemetry, [:shanghai, :storage, :compaction, :complete], %{duration_ms: 10}, _}
  end

  test "query_operation_completed emits a query event" do
    Metrics.query_operation_completed(:read, 0.2, :ok)
    assert_receive {:telemetry, [:shanghai, :query, :operation], _, %{operation: :read, result: :ok}}
  end
end
