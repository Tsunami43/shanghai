defmodule Storage.Persistence.SerializerTest do
  use ExUnit.Case, async: true

  alias Storage.Persistence.Serializer

  describe "encode/1 and decode/1" do
    test "round-trip encoding and decoding simple data" do
      data = "test string"
      assert {:ok, binary} = Serializer.encode(data)
      assert is_binary(binary)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "round-trip with maps" do
      data = %{key: "value", number: 42, list: [1, 2, 3]}
      assert {:ok, binary} = Serializer.encode(data)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "round-trip with lists" do
      data = [1, "two", :three, %{four: 4}]
      assert {:ok, binary} = Serializer.encode(data)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "round-trip with structs" do
      data = %CoreDomain.Types.LogSequenceNumber{value: 123}
      assert {:ok, binary} = Serializer.encode(data)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "round-trip with tuples" do
      data = {:ok, "value", 123}
      assert {:ok, binary} = Serializer.encode(data)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "round-trip with nil" do
      data = nil
      assert {:ok, binary} = Serializer.encode(data)
      assert {:ok, ^data} = Serializer.decode(binary)
    end

    test "decode returns error for invalid binary" do
      assert {:error, :invalid_binary} = Serializer.decode(<<1, 2, 3>>)
    end

    test "decode returns error for non-binary input" do
      assert {:error, :not_a_binary} = Serializer.decode(123)
      assert {:error, :not_a_binary} = Serializer.decode(:atom)
    end

    test "encoded data includes version metadata" do
      {:ok, binary} = Serializer.encode("test")
      wrapped = :erlang.binary_to_term(binary, [:safe])

      assert wrapped.version == 1
      assert wrapped.format == :etf
      assert %DateTime{} = wrapped.created_at
      assert wrapped.data == "test"
    end
  end

  describe "encode_with_checksum/1 and decode_with_checksum/1" do
    test "round-trip with checksum validation" do
      data = %{important: "data", value: 42}
      assert {:ok, binary} = Serializer.encode_with_checksum(data)
      assert {:ok, ^data} = Serializer.decode_with_checksum(binary)
    end

    test "detects corrupted data" do
      {:ok, binary} = Serializer.encode_with_checksum("original data")

      # Corrupt the data part (skip first 4 bytes which are checksum)
      <<checksum::32, rest::binary>> = binary
      corrupted = <<checksum::32, "corrupted", rest::binary>>

      assert {:error, :corrupt_data} = Serializer.decode_with_checksum(corrupted)
    end

    test "returns error for invalid checksum format" do
      # Binary too short to contain checksum
      assert {:error, :invalid_checksum_format} = Serializer.decode_with_checksum(<<1, 2, 3>>)
    end

    test "returns error for non-binary input" do
      assert {:error, :not_a_binary} = Serializer.decode_with_checksum(:not_binary)
    end

    test "checksum is 4 bytes" do
      {:ok, binary} = Serializer.encode_with_checksum("test")
      <<checksum::32, _rest::binary>> = binary

      assert is_integer(checksum)
    end
  end

  describe "compute_checksum/1" do
    test "computes CRC32 checksum" do
      checksum = Serializer.compute_checksum("test data")
      assert is_integer(checksum)
      assert checksum >= 0
    end

    test "same data produces same checksum" do
      data = "consistent data"
      checksum1 = Serializer.compute_checksum(data)
      checksum2 = Serializer.compute_checksum(data)
      assert checksum1 == checksum2
    end

    test "different data produces different checksums" do
      checksum1 = Serializer.compute_checksum("data1")
      checksum2 = Serializer.compute_checksum("data2")
      assert checksum1 != checksum2
    end
  end

  describe "version handling" do
    test "validates current version" do
      {:ok, binary} = Serializer.encode("test")
      assert {:ok, "test"} = Serializer.decode(binary)
    end

    test "rejects future versions" do
      # Manually create a binary with future version
      future_wrapped = %{
        version: 999,
        format: :etf,
        created_at: DateTime.utc_now(),
        data: "test"
      }

      binary = :erlang.term_to_binary(future_wrapped, [:compressed])

      assert {:error, {:unsupported_version, 999, :too_new}} = Serializer.decode(binary)
    end

    test "rejects invalid version types" do
      invalid_wrapped = %{
        version: "not_a_number",
        format: :etf,
        created_at: DateTime.utc_now(),
        data: "test"
      }

      binary = :erlang.term_to_binary(invalid_wrapped, [:compressed])
      assert {:error, :invalid_version} = Serializer.decode(binary)
    end
  end

  describe "format handling" do
    test "accepts ETF format" do
      {:ok, binary} = Serializer.encode("test")
      assert {:ok, "test"} = Serializer.decode(binary)
    end

    test "rejects unsupported formats" do
      invalid_wrapped = %{
        version: 1,
        format: :json,
        created_at: DateTime.utc_now(),
        data: "test"
      }

      binary = :erlang.term_to_binary(invalid_wrapped, [:compressed])
      assert {:error, {:unsupported_format, :json}} = Serializer.decode(binary)
    end
  end

  describe "large data handling" do
    test "handles large data structures" do
      large_data = for i <- 1..10_000, into: %{}, do: {"key_#{i}", "value_#{i}"}

      assert {:ok, binary} = Serializer.encode(large_data)
      assert {:ok, ^large_data} = Serializer.decode(binary)
    end

    test "handles deeply nested structures" do
      nested =
        Enum.reduce(1..100, %{value: "deep"}, fn i, acc ->
          %{"level_#{i}" => acc}
        end)

      assert {:ok, binary} = Serializer.encode(nested)
      assert {:ok, ^nested} = Serializer.decode(binary)
    end
  end

  describe "compression" do
    test "compressed binary is smaller for repetitive data" do
      repetitive_data = String.duplicate("repeat", 1000)

      {:ok, compressed_binary} = Serializer.encode(repetitive_data)
      uncompressed_binary = :erlang.term_to_binary(repetitive_data)

      assert byte_size(compressed_binary) < byte_size(uncompressed_binary)
    end
  end
end
