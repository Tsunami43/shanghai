defmodule Shanghai.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.2.0",
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
      "test.disk": [&test_on_disk/1],
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  # Runs the suite against a real filesystem.
  #
  # Tests place their data under `System.tmp_dir!/0`, which is `/tmp` - tmpfs on
  # most Linux systems. An fsync there is a memory barrier rather than a disk
  # flush, so crash-recovery and group-commit tests never exercise real
  # durability. `System.tmp_dir!/0` honours TMPDIR, so pointing it at a real
  # filesystem redirects every test without changing any of them.
  #
  # Override the location with SHANGHAI_TEST_DIR; it defaults to ./tmp/test,
  # which is git-ignored and lives on whatever disk the checkout is on.
  defp test_on_disk(args) do
    dir = System.get_env("SHANGHAI_TEST_DIR") || Path.join(File.cwd!(), "tmp/test")
    File.mkdir_p!(dir)
    System.put_env("TMPDIR", dir)

    Mix.shell().info("Running tests against #{dir} (verify it is not tmpfs: df -T #{dir})")

    Mix.Task.run("test.all", args)
  end

  defp dialyzer do
    [
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
          admin: :permanent,
          admin_api: :permanent
        ]
      ]
    ]
  end
end
