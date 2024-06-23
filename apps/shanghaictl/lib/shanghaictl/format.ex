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

  @doc """
  Formats a ratio in `0.0..1.0` as a percentage string with one decimal place.

  ## Examples

      iex> Shanghaictl.Format.percent(0.42)
      "42.0%"

      iex> Shanghaictl.Format.percent(1.0)
      "100.0%"
  """
  @spec percent(number()) :: String.t()
  def percent(ratio) when is_number(ratio) do
    rounded = Float.round(ratio * 100, 1)
    "#{:erlang.float_to_binary(rounded, decimals: 1)}%"
  end

  @doc """
  Formats a millisecond duration in a human-readable form: `ms` below a second,
  `s` below a minute, otherwise `m`.

  ## Examples

      iex> Shanghaictl.Format.duration_ms(500)
      "500ms"

      iex> Shanghaictl.Format.duration_ms(1_500)
      "1.5s"

      iex> Shanghaictl.Format.duration_ms(90_000)
      "1.5m"
  """
  @spec duration_ms(non_neg_integer()) :: String.t()
  def duration_ms(ms) when is_integer(ms) and ms >= 0 and ms < 1_000, do: "#{ms}ms"

  def duration_ms(ms) when is_integer(ms) and ms < 60_000 do
    "#{:erlang.float_to_binary(Float.round(ms / 1_000, 1), decimals: 1)}s"
  end

  def duration_ms(ms) when is_integer(ms) do
    "#{:erlang.float_to_binary(Float.round(ms / 60_000, 1), decimals: 1)}m"
  end

  @doc """
  Truncates `string` to at most `max` characters, appending an ellipsis (`…`)
  when it is shortened. `max` must be at least 1.

  ## Examples

      iex> Shanghaictl.Format.truncate("hello world", 8)
      "hello w…"

      iex> Shanghaictl.Format.truncate("short", 8)
      "short"
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(string, max) when is_binary(string) and is_integer(max) and max >= 1 do
    if String.length(string) <= max do
      string
    else
      String.slice(string, 0, max - 1) <> "…"
    end
  end

  @doc """
  Renders a boolean as `"yes"`/`"no"` for human-readable CLI output.

  ## Examples

      iex> Shanghaictl.Format.yes_no(true)
      "yes"

      iex> Shanghaictl.Format.yes_no(false)
      "no"
  """
  @spec yes_no(boolean()) :: String.t()
  def yes_no(true), do: "yes"
  def yes_no(false), do: "no"
end
