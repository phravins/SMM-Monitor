defmodule SmmMonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :smm_monitor,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      description: "Terminal UI for monitoring client brand mentions across social platforms.",
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # The OTP application. `SmmMonitor.Application` starts the supervision tree
  # (fetchers + processing). The TUI is *not* part of the tree by default so
  # that `mix test` and headless runs never try to grab the terminal.
  def application do
    [
      extra_applications: [:logger],
      mod: {SmmMonitor.Application, []}
    ]
  end

  # `mix release` is the shippable build. An escript is *not* viable here:
  # Ratatouille's termbox NIF can't be loaded out of an escript archive, so
  # the binary would start and immediately fail on `ExTermbox.Bindings.init/0`.
  defp releases do
    [
      smm_monitor: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # TUI. Ratatouille wraps termbox and gives us an Elm-style app behaviour.
      {:ratatouille, "~> 0.5.1"},
      # HTTP client for the real platform APIs.
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Durable storage for collected mentions. ecto_sqlite3 is the
      # standard Elixir/SQLite pairing and uses exqlite as its driver, so
      # this isn't a choice against exqlite - exqlite still does the work.
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"}
    ]
  end
end
