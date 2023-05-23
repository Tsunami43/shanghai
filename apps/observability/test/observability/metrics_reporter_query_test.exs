defmodule Observability.MetricsReporterQueryTest do
  @moduledoc "The metrics reporter aggregates query operation telemetry."

  use ExUnit.Case, async: false

  alias Observability.{Metrics, MetricsReporter}

  test "aggregates query operations by operation name" do
    # A synthetic operation name no other code emits, so counts are deterministic.
    Metrics.query_operation_completed(:probe_query_op, 2.0, :ok)
    Metrics.query_operation_completed(:probe_query_op, 4.0, :ok)

    # get_query_stats is a call, processed after the telemetry sends above.
    stats = MetricsReporter.get_query_stats()

    probe = stats[:probe_query_op]
    assert probe.count == 2
    assert probe.sum == 6.0
  end
end
