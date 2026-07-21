defmodule Admin.MixProject do
  use Mix.Project

  def project do
    [
      app: :admin,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # A library app: it composes the other contexts (see `Admin.Health`) and owns
  # no processes, so it has no `mod:` and starts no supervisor.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:core_domain, in_umbrella: true},
      {:storage, in_umbrella: true},
      {:cluster, in_umbrella: true},
      {:replication, in_umbrella: true},
      {:query, in_umbrella: true}
    ]
  end
end
