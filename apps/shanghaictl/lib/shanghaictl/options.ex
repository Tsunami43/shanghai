defmodule Shanghaictl.Options do
  @moduledoc """
  Shared parsing helpers for CLI command options (a raw list of string args).
  """

  @default_admin_url "http://localhost:9090"

  @doc """
  Returns the output format requested by the args: `:json` when `--json` or
  `--format json` is present, otherwise `:text`.

  ## Examples

      iex> Shanghaictl.Options.format(["--format", "json"])
      :json

      iex> Shanghaictl.Options.format(["--json"])
      :json

      iex> Shanghaictl.Options.format([])
      :text
  """
  @spec format([String.t()]) :: :json | :text
  def format(args) do
    json? =
      "--json" in args or
        args
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.any?(&(&1 == ["--format", "json"]))

    if json?, do: :json, else: :text
  end

  @doc """
  Returns the admin URL, resolved in order of precedence:

  1. `--admin-url URL` or `--admin-url=URL` from the args
  2. the `SHANGHAI_ADMIN_URL` environment variable
  3. the default (`http://localhost:9090`)

  ## Examples

      iex> Shanghaictl.Options.admin_url(["--admin-url", "http://h:9090"])
      "http://h:9090"

      iex> Shanghaictl.Options.admin_url(["--admin-url=http://h:1"])
      "http://h:1"
  """
  @spec admin_url([String.t()]) :: String.t()
  def admin_url(args) do
    from_args(args) || from_env() || @default_admin_url
  end

  @doc """
  Returns `true` when the boolean flag `--name` is present in `args`.

  ## Examples

      iex> Shanghaictl.Options.flag?(["--verbose"], "verbose")
      true

      iex> Shanghaictl.Options.flag?([], "verbose")
      false
  """
  @spec flag?([String.t()], String.t()) :: boolean()
  def flag?(args, name) when is_binary(name) do
    ("--" <> name) in args
  end

  @doc """
  Returns the value of the `--name value` or `--name=value` option, or `default`
  when the option is absent. The `--name=value` form takes precedence.

  ## Examples

      iex> Shanghaictl.Options.option(["--limit", "10"], "limit")
      "10"

      iex> Shanghaictl.Options.option(["--limit=5"], "limit")
      "5"

      iex> Shanghaictl.Options.option([], "limit", "20")
      "20"
  """
  @spec option([String.t()], String.t(), String.t() | nil) :: String.t() | nil
  def option(args, name, default \\ nil) when is_binary(name) do
    prefix = "--" <> name <> "="
    flag = "--" <> name

    equals =
      Enum.find_value(args, fn
        ^prefix <> value -> value
        _ -> nil
      end)

    value =
      equals ||
        case Enum.drop_while(args, &(&1 != flag)) do
          [^flag, value | _rest] -> value
          _ -> nil
        end

    value || default
  end

  @doc """
  Returns the integer value of the `--name` option, or `default` when the option
  is absent or is not a valid integer.

  ## Examples

      iex> Shanghaictl.Options.int_option(["--limit", "10"], "limit", 100)
      10

      iex> Shanghaictl.Options.int_option(["--limit=x"], "limit", 100)
      100

      iex> Shanghaictl.Options.int_option([], "limit", 100)
      100
  """
  @spec int_option([String.t()], String.t(), integer()) :: integer()
  def int_option(args, name, default) when is_integer(default) do
    case option(args, name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {int, ""} -> int
          _ -> default
        end
    end
  end

  defp from_args(args), do: option(args, "admin-url")

  defp from_env do
    case System.get_env("SHANGHAI_ADMIN_URL") do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
