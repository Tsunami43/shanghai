defmodule Shanghaictl.Format do
  @moduledoc """
  Small pure formatting helpers for human-readable CLI output.
  """

  @units ["B", "KB", "MB", "GB", "TB", "PB"]

  @doc """
  Formats a byte count as a human-readable string using base-1024 units.

  Values below 1 KB are shown as whole bytes; larger values use one decimal
  place and the largest unit that keeps the number below 1024.

  ## Examples

      iex> Shanghaictl.Format.bytes(512)
      "512 B"

      iex> Shanghaictl.Format.bytes(1536)
      "1.5 KB"

      iex> Shanghaictl.Format.bytes(1_048_576)
      "1.0 MB"
  """
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) when is_integer(n) and n >= 0 do
    scale(n / 1, 0)
  end

  defp scale(value, unit_index) when value >= 1024 and unit_index < length(@units) - 1 do
    scale(value / 1024, unit_index + 1)
  end

  defp scale(value, 0), do: "#{trunc(value)} B"

  defp scale(value, unit_index) do
    rounded = Float.round(value, 1)
    "#{:erlang.float_to_binary(rounded, decimals: 1)} #{Enum.at(@units, unit_index)}"
  end

  @doc """
  Formats an integer with thousands separators (underscores are avoided in
  favor of the conventional comma).

  ## Examples

      iex> Shanghaictl.Format.count(1_234_567)
      "1,234,567"

      iex> Shanghaictl.Format.count(42)
      "42"
  """
  @spec count(integer()) :: String.t()
  def count(n) when is_integer(n) and n < 0, do: "-" <> count(-n)

  def count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
