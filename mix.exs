defmodule SmmMonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :smm_monitor,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
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

  defp escript do
    [main_module: SmmMonitor.CLI, name: "smm_monitor"]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # TUI. Ratatouille wraps termbox and gives us an Elm-style app behaviour.
      {:ratatouille, "~> 0.5.1"},
      # HTTP client for the real platform APIs.
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
