defmodule Shanghai.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Shared development dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test --color"],
      "test.all": ["cmd mix test --color"],
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp releases do
    [
      shanghai: [
        applications: [
          core_domain: :permanent,
          storage: :permanent,
          cluster: :permanent,
          replication: :permanent,
          query: :permanent,
          admin: :permanent
        ]
      ]
    ]
  end
end
