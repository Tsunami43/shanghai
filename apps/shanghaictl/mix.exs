defmodule Shanghaictl.MixProject do
  use Mix.Project

  def project do
    [
      app: :shanghaictl,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      # shanghaictl is a client CLI that talks to a node's Admin API over HTTP,
      # so it is built as a standalone escript rather than shipped inside the
      # server release. Build it from this directory with `mix escript.build`;
      # the resulting `shanghaictl` binary runs anywhere with an Erlang runtime.
      escript: [main_module: Shanghaictl],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    # A pure Admin-API HTTP client: req + jason only. It deliberately does NOT
    # depend on the server apps (cluster, replication, ...); doing so dragged
    # their whole OTP boot into the escript, so running the CLI started a node.
    [
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
