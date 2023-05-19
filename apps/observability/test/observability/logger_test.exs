defmodule Observability.LoggerTest do
  @moduledoc "Correlation-id lifecycle for structured logging."

  use ExUnit.Case, async: true

  alias Observability.Logger, as: Log

  setup do
    Process.delete(:correlation_id)
    :ok
  end

  test "put/get round-trips the correlation id" do
    assert Log.get_correlation_id() == nil
    Log.put_correlation_id("abc")
    assert Log.get_correlation_id() == "abc"
  end

  test "with_correlation_id sets it during the function and clears it afterwards" do
    assert Log.get_correlation_id() == nil

    inside = Log.with_correlation_id("cid-1", fn -> Log.get_correlation_id() end)

    assert inside == "cid-1"
    assert Log.get_correlation_id() == nil
  end

  test "with_correlation_id restores a previously set id" do
    Log.put_correlation_id("outer")

    Log.with_correlation_id("inner", fn ->
      assert Log.get_correlation_id() == "inner"
    end)

    assert Log.get_correlation_id() == "outer"
  end

  test "with_correlation_id restores even when the function raises" do
    Log.put_correlation_id("outer")

    assert_raise RuntimeError, fn ->
      Log.with_correlation_id("inner", fn -> raise "boom" end)
    end

    assert Log.get_correlation_id() == "outer"
  end

  test "new_correlation_id produces distinct lowercase hex ids" do
    a = Log.new_correlation_id()
    b = Log.new_correlation_id()

    assert a =~ ~r/^[0-9a-f]{32}$/
    assert a != b
  end
end
