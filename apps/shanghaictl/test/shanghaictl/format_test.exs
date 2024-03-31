defmodule Shanghaictl.FormatTest do
  use ExUnit.Case, async: true

  alias Shanghaictl.Format

  doctest Format

  describe "bytes/1" do
    test "formats byte counts across units" do
      assert Format.bytes(0) == "0 B"
      assert Format.bytes(512) == "512 B"
      assert Format.bytes(1023) == "1023 B"
      assert Format.bytes(1024) == "1.0 KB"
      assert Format.bytes(1536) == "1.5 KB"
      assert Format.bytes(1_048_576) == "1.0 MB"
      assert Format.bytes(1_073_741_824) == "1.0 GB"
    end
  end

  describe "count/1" do
    test "inserts thousands separators" do
      assert Format.count(0) == "0"
      assert Format.count(42) == "42"
      assert Format.count(1_000) == "1,000"
      assert Format.count(1_234_567) == "1,234,567"
    end

    test "handles negative numbers" do
      assert Format.count(-1_234) == "-1,234"
    end
  end

  describe "percent/1" do
    test "formats ratios as percentages" do
      assert Format.percent(0.0) == "0.0%"
      assert Format.percent(0.42) == "42.0%"
      assert Format.percent(1.0) == "100.0%"
      assert Format.percent(2 / 3) == "66.7%"
    end
  end

  describe "duration_ms/1" do
    test "formats durations across units" do
      assert Format.duration_ms(0) == "0ms"
      assert Format.duration_ms(500) == "500ms"
      assert Format.duration_ms(1_500) == "1.5s"
      assert Format.duration_ms(59_000) == "59.0s"
      assert Format.duration_ms(90_000) == "1.5m"
    end
  end
end
