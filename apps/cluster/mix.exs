defmodule Cluster.MixProject do
  use Mix.Project

  def project do
    [
      app: :cluster,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    extra_applications = [:logger]

    if Mix.env() == :test do
      [extra_applications: extra_applications]
    else
      [extra_applications: extra_applications, mod: {Cluster.Application, []}]
    end
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:core_domain, in_umbrella: true}
    ]
  end
end
