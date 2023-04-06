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
      # Read-through cache in front of the store.
      Query.Cache
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Query.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
