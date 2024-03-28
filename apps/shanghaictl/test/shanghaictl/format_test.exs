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
end
