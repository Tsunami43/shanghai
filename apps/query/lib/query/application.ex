defmodule Query.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Materialized KV store backing the public Query API.
      Query.Store,
      # Read-through cache in front of the store, tunable via config.
      {Query.Cache, cache_opts()}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Query.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Reads the read-cache tuning from application config. Operators can size the
  cache and set an entry TTL without code changes:

      config :query, :cache, max_size: 50_000, ttl_ms: 60_000

  Unknown keys are ignored so the cache only ever receives options it accepts.
  """
  @spec cache_opts() :: keyword()
  def cache_opts do
    config = Application.get_env(:query, :cache, [])
    Keyword.take(config, [:max_size, :ttl_ms])
  end
end
