defmodule Observability.MetricsReporterCompactionTest do
  @moduledoc "The reporter aggregates compaction-complete telemetry."

  use ExUnit.Case, async: false

  alias Observability.{Metrics, MetricsReporter}

  test "compaction_completed updates count, duration and reclaimed bytes" do
    before = MetricsReporter.get_compaction_stats()

    # :telemetry.execute runs handlers inline, so the reporter has the event in
    # its mailbox before the following synchronous call is processed.
    Metrics.compaction_completed(12, 1000, 400, ["seg-1"])

    after_stats = MetricsReporter.get_compaction_stats()

    assert after_stats.count == before.count + 1
    assert after_stats.last_duration_ms == 12
    assert after_stats.bytes_reclaimed == before.bytes_reclaimed + 600
  end
end
