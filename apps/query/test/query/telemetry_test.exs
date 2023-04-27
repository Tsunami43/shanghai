defmodule Query.TelemetryTest do
  @moduledoc """
  Verifies that the query layer is observable by default: every user-facing
  operation emits a `[:shanghai, :query, :operation]` telemetry event.
  """

  use ExUnit.Case, async: false

  @event [:shanghai, :query, :operation]

  setup do
    Query.Store.reset()
    Query.Cache.clear()

    handler_id = "query-telemetry-test-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "write emits a telemetry event with duration and result" do
    {:ok, :written} = Query.write("k", "v")

    assert_receive {:telemetry, @event, %{duration_ms: duration}, %{operation: :write, result: :ok}}
    assert is_number(duration) and duration >= 0
  end

  test "read of a missing key emits an :error result" do
    {:error, :not_found} = Query.read("missing")

    assert_receive {:telemetry, @event, _measurements, %{operation: :read, result: :error}}
  end

  test "delete and transact emit their own operation tags" do
    {:ok, :deleted} = Query.delete("k")
    assert_receive {:telemetry, @event, _m, %{operation: :delete, result: :ok}}

    {:ok, :committed} = Query.transact([{:write, "k", "v"}])
    assert_receive {:telemetry, @event, _m, %{operation: :transact, result: :ok}}
  end
end
