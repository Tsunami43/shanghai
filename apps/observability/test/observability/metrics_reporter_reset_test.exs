defmodule Observability.MetricsReporterResetTest do
  @moduledoc "reset/0 clears the reporter's aggregated statistics."

  use ExUnit.Case, async: false

  alias Observability.{Metrics, MetricsReporter}

  test "reset clears accumulated query and compaction stats" do
    Metrics.query_operation_completed(:read, 1.0, :ok)
    Metrics.compaction_completed(5, 100, 40, ["seg-1"])

    # Events run inline, so they are enqueued before this synchronous call.
    assert MetricsReporter.get_query_stats() != %{}

    :ok = MetricsReporter.reset()

    assert MetricsReporter.get_query_stats() == %{}
    assert MetricsReporter.get_compaction_stats().count == 0
    assert MetricsReporter.get_wal_stats() == %{writes: %{}, syncs: %{}}
  end
end
