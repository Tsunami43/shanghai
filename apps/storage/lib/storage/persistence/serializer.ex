defmodule Storage.Persistence.Serializer do
  @moduledoc """
  Handles serialization/deserialization with versioning.

  Uses Erlang Term Format (ETF) with metadata wrapper to enable:
  - Version tracking for format migration
  - Timestamp tracking for debugging/auditing
  - Checksum validation for data integrity

  ## Examples

      iex> {:ok, binary} = Serializer.encode(%{key: "value"})
      iex> {:ok, data} = Serializer.decode(binary)
      iex> data
      %{key: "value"}

      iex> {:ok, binary} = Serializer.encode_with_checksum("important data")
      iex> {:ok, data} = Serializer.decode_with_checksum(binary)
      iex> data
      "important data"
  """

  @current_version 1

  @type serialized_data :: %{
          version: non_neg_integer(),
          format: :etf,
          created_at: DateTime.t(),
          data: term()
        }

  @type checksum :: binary()

  @doc """
  Encodes data with versioning metadata.

  Wraps the data in a structure containing version and timestamp information,
  then converts to Erlang Term Format with compression.

  ## Examples

      iex> Serializer.encode(%{test: "data"})
      {:ok, <<...>>}

      iex> Serializer.encode([1, 2, 3])
      {:ok, <<...>>}
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(data) do
    wrapped = %{
      version: @current_version,
      format: :etf,
      created_at: DateTime.utc_now(),
      data: data
    }

    binary = :erlang.term_to_binary(wrapped, [:compressed])
    {:ok, binary}
  rescue
    e in ArgumentError ->
      {:error, {:serialization_failed, Exception.message(e)}}

    e ->
      {:error, {:serialization_failed, e}}
  end

  @doc """
  Decodes data and validates version.

  Extracts the original data from the versioned wrapper, validating
  that we can handle the serialized version.

  ## Examples

      iex> {:ok, binary} = Serializer.encode("test")
      iex> Serializer.decode(binary)
      {:ok, "test"}
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    wrapped = :erlang.binary_to_term(binary, [:safe])

    with :ok <- validate_version(wrapped.version),
         :ok <- validate_format(wrapped.format) do
      {:ok, wrapped.data}
    end
  rescue
    ArgumentError ->
      {:error, :invalid_binary}

    e ->
      {:error, {:deserialization_failed, e}}
  end

  def decode(_), do: {:error, :not_a_binary}

  @doc """
  Encodes data with CRC32 checksum for integrity validation.

  Format: [checksum:32][serialized_data]

  ## Examples

      iex> {:ok, binary} = Serializer.encode_with_checksum(%{important: "data"})
      iex> byte_size(binary) > 4
      true
  """
  @spec encode_with_checksum(term()) :: {:ok, binary()} | {:error, term()}
  def encode_with_checksum(data) do
    with {:ok, serialized} <- encode(data) do
      checksum = compute_checksum(serialized)
      {:ok, <<checksum::32, serialized::binary>>}
    end
  end

  @doc """
  Decodes data and validates CRC32 checksum.

  Returns error if checksum doesn't match, indicating corruption.

  ## Examples

      iex> {:ok, binary} = Serializer.encode_with_checksum("test")
      iex> Serializer.decode_with_checksum(binary)
      {:ok, "test"}

      iex> # Corrupt data
      iex> Serializer.decode_with_checksum(<<1, 2, 3, 4, 5>>)
      {:error, :corrupt_data}
  """
  @spec decode_with_checksum(binary()) :: {:ok, term()} | {:error, term()}
  def decode_with_checksum(<<stored_checksum::32, serialized::binary>>) do
    computed_checksum = compute_checksum(serialized)

    if stored_checksum == computed_checksum do
      decode(serialized)
    else
      {:error, :corrupt_data}
    end
  end

  def decode_with_checksum(binary) when byte_size(binary) < 4 do
    {:error, :invalid_checksum_format}
  end

  def decode_with_checksum(_), do: {:error, :not_a_binary}

  @doc """
  Computes CRC32 checksum for binary data.

  ## Examples

      iex> checksum = Serializer.compute_checksum("test data")
      iex> is_integer(checksum)
      true
  """
  @spec compute_checksum(binary()) :: non_neg_integer()
  def compute_checksum(binary) when is_binary(binary) do
    :erlang.crc32(binary)
  end

  # Private functions

  @spec validate_version(non_neg_integer()) :: :ok | {:error, term()}
  defp validate_version(@current_version), do: :ok

  defp validate_version(version) when is_integer(version) and version < @current_version do
    # Future: Add migration path for old versions
    {:error, {:unsupported_version, version, :too_old}}
  end

  defp validate_version(version) when is_integer(version) do
    {:error, {:unsupported_version, version, :too_new}}
  end

  defp validate_version(_), do: {:error, :invalid_version}

  @spec validate_format(atom()) :: :ok | {:error, term()}
  defp validate_format(:etf), do: :ok
  defp validate_format(format), do: {:error, {:unsupported_format, format}}
end
