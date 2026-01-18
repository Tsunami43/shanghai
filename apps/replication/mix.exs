defmodule Replication.MixProject do
  use Mix.Project

  def project do
    [
      app: :replication,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Replication.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:core_domain, in_umbrella: true},
      {:storage, in_umbrella: true},
      {:cluster, in_umbrella: true},
      {:observability, in_umbrella: true}
    ]
  end
end
