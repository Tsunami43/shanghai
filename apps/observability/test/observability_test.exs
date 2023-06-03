defmodule ObservabilityTest do
  use ExUnit.Case, async: true

  doctest Observability

  test "event_names/0 lists the known telemetry events" do
    names = Observability.event_names()

    assert [:shanghai, :query, :operation] in names
    assert [:shanghai, :storage, :wal, :write] in names
  end

  test "new_correlation_id/0 returns a hex string" do
    id = Observability.new_correlation_id()

    assert is_binary(id)
    assert id =~ ~r/^[0-9a-f]+$/
  end
end
