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
  Returns the admin URL from a `--admin-url URL` pair, or the default
  (`http://localhost:9090`).

  ## Examples

      iex> Shanghaictl.Options.admin_url(["--admin-url", "http://h:9090"])
      "http://h:9090"

      iex> Shanghaictl.Options.admin_url([])
      "http://localhost:9090"
  """
  @spec admin_url([String.t()]) :: String.t()
  def admin_url(args) do
    case Enum.drop_while(args, &(&1 != "--admin-url")) do
      ["--admin-url", url | _rest] -> url
      _ -> @default_admin_url
    end
  end
end
