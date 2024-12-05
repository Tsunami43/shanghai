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

  describe "truncate/2" do
    test "shortens long strings with an ellipsis" do
      assert Format.truncate("hello world", 8) == "hello w…"
      assert Format.truncate("short", 8) == "short"
      assert Format.truncate("exact8ch", 8) == "exact8ch"
      assert Format.truncate("abcdef", 3) == "ab…"
    end
  end

  describe "yes_no/1" do
    test "renders booleans" do
      assert Format.yes_no(true) == "yes"
      assert Format.yes_no(false) == "no"
    end
  end

  describe "list/1" do
    test "joins items or shows none" do
      assert Format.list([:a, :b, :c]) == "a, b, c"
      assert Format.list(["x"]) == "x"
      assert Format.list([]) == "none"
    end
  end

  describe "pluralize/3" do
    test "pluralizes based on count" do
      assert Format.pluralize(1, "node") == "1 node"
      assert Format.pluralize(0, "node") == "0 nodes"
      assert Format.pluralize(3, "node") == "3 nodes"
      assert Format.pluralize(2, "entry", "entries") == "2 entries"
    end
  end

  describe "dash/1" do
    test "renders nil as a dash" do
      assert Format.dash(nil) == "-"
      assert Format.dash(42) == "42"
      assert Format.dash("x") == "x"
    end
  end

  describe "pad/2" do
    test "right-pads to the requested width" do
      assert Format.pad("id", 5) == "id   "
      assert Format.pad("longvalue", 5) == "longvalue"
      assert Format.pad(42, 4) == "42  "
    end
  end

  describe "kv/3" do
    test "renders an aligned key/value line" do
      assert Format.kv("Status", "up", 8) == "Status  : up"
      assert Format.kv("A", 1) == "A: 1"
    end
  end

  describe "count_label/3" do
    test "shows none for zero and pluralizes otherwise" do
      assert Format.count_label(0, "node") == "none"
      assert Format.count_label(1, "node") == "1 node"
      assert Format.count_label(2, "node") == "2 nodes"
      assert Format.count_label(3, "entry", "entries") == "3 entries"
    end
  end
end
