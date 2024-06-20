defmodule ObservabilityTest do
  use ExUnit.Case, async: true

  doctest Observability

  test "event_names/0 lists the known telemetry events" do
    names = Observability.event_names()

    assert [:shanghai, :query, :operation] in names
    assert [:shanghai, :storage, :wal, :write] in names
  end

  test "event_defined?/1 and event_count/0 mirror Metrics" do
    assert Observability.event_defined?([:shanghai, :query, :operation])
    refute Observability.event_defined?([:shanghai, :nope])
    assert Observability.event_count() == length(Observability.event_names())
  end

  test "new_correlation_id/0 returns a hex string" do
    id = Observability.new_correlation_id()

    assert is_binary(id)
    assert id =~ ~r/^[0-9a-f]+$/
  end

  test "correlation_id/0 reflects the current process correlation id" do
    Process.delete(:correlation_id)
    assert Observability.correlation_id() == nil
    id = Observability.ensure_correlation_id()
    assert Observability.correlation_id() == id
  end

  test "ensure_correlation_id/0 returns a stable id within the process" do
    Process.delete(:correlation_id)
    id = Observability.ensure_correlation_id()

    assert is_binary(id)
    assert Observability.ensure_correlation_id() == id
  end

  test "stats/0 returns the aggregated metric sections" do
    stats = Observability.stats()

    assert Map.has_key?(stats, :wal)
    assert Map.has_key?(stats, :replication)
    assert Map.has_key?(stats, :heartbeat)
    assert Map.has_key?(stats, :query)
  end

  test "per-section accessors return maps consistent with stats/0" do
    stats = Observability.stats()

    assert Observability.wal_stats() == stats.wal
    assert Observability.replication_stats() == stats.replication
    assert Observability.query_stats() == stats.query
  end
end
