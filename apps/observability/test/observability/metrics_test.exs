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

    assert_receive {:telemetry, [:shanghai, :storage, :compaction, :complete], %{duration_ms: 10},
                    _}
  end

  test "query_operation_completed emits a query event" do
    Metrics.query_operation_completed(:read, 0.2, :ok)

    assert_receive {:telemetry, [:shanghai, :query, :operation], _,
                    %{operation: :read, result: :ok}}
  end

  test "domain_event_counts/0 counts events per domain" do
    counts = Metrics.domain_event_counts()
    assert counts[:query] == 1
    assert counts[:storage] >= 1
    assert Enum.sum(Map.values(counts)) == Metrics.event_count()
  end

  test "domains/0 lists the distinct sorted domains" do
    domains = Metrics.domains()
    assert :query in domains
    assert :storage in domains
    assert domains == Enum.sort(Enum.uniq(domains))
  end

  test "events_for_domain/1 filters by the second path segment" do
    query = Metrics.events_for_domain(:query)
    assert query == [[:shanghai, :query, :operation]]

    storage = Metrics.events_for_domain(:storage)
    assert Enum.all?(storage, fn [:shanghai, :storage | _] -> true end)
    assert [:shanghai, :storage, :wal, :write] in storage

    assert Metrics.events_for_domain(:nope) == []
  end

  test "domain?/1 reflects whether a domain emits events" do
    assert Metrics.domain?(:query)
    assert Metrics.domain?(:storage)
    refute Metrics.domain?(:nope)
  end

  test "event_defined?/1 and event_count/0 describe the known events" do
    assert Metrics.event_defined?([:shanghai, :query, :operation])
    refute Metrics.event_defined?([:shanghai, :nope])
    assert Metrics.event_count() == length(Metrics.event_names())
  end
end
