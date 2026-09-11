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

  # Two releases, for two very different audiences.
  #
  # `smm_monitor` is the server build: `mix release smm_monitor`, deployed
  # under systemd, dashboards served over SSH. It is untouched by the
  # desktop work — same name, same layout, same scripts.
  #
  # `standalone` is the desktop build: `mix release standalone` wraps the
  # same code in a Burrito binary, one file per OS, which somebody can
  # download and run without installing Elixir, Erlang or anything else.
  #
  # An escript is *not* viable for either: Ratatouille's termbox NIF can't
  # be loaded out of an escript archive, so the binary would start and
  # immediately fail on `ExTermbox.Bindings.init/0`.
  defp releases do
    [
      smm_monitor: [
        include_executables_for: [:unix],
        # Bundle the Erlang runtime so the target server needs neither
        # Elixir nor Erlang installed. The trade is that the release is
        # tied to the OS and architecture it was built on.
        include_erts: true,
        # runtime_tools gives :observer/:recon a foothold if someone ever
        # needs to attach to a misbehaving instance.
        applications: [runtime_tools: :permanent],
        # Strip debug info: smaller release, and nothing on a production
        # box needs to decompile it.
        strip_beams: true
      ],
      standalone: [
        steps: [:assemble, &Burrito.wrap/1],
        include_erts: true,
        strip_beams: true,
        applications: [runtime_tools: :permanent],
        burrito: [
          targets: burrito_targets()
        ]
      ]
    ]
  end

  # One target per file we publish. `BURRITO_TARGET=linux mix release
  # standalone` builds just that one, which is how the release workflow
  # keeps each build on the operating system it is for.
  #
  # Apple Silicon and Intel Macs are separate binaries because a Burrito
  # binary carries one ERTS, and the install script picks by `uname -m`.
  # One entry per file the release workflow publishes. All four are
  # cross-built from a single Linux machine — Burrito's whole trick —
  # and `BURRITO_TARGET=linux mix release standalone` builds just one.
  #
  # There is no Windows target, and it isn't an oversight. Ratatouille
  # draws through termbox, and termbox is POSIX:
  #
  #     termbox.c:9:10: fatal error: 'sys/select.h' file not found
  #
  # No compiler flag fixes that — the library is written against termios
  # and select. Windows users install into WSL instead, which is what
  # scripts/install.ps1 sets up; see the README. The day termbox learns
  # to speak to the Windows console, one line here is the whole change.
  defp burrito_targets do
    [
      linux: target(:linux, :x86_64),
      linux_arm: target(:linux, :aarch64),
      macos: target(:darwin, :aarch64),
      macos_intel: target(:darwin, :x86_64)
    ]
  end

  # Burrito bundles a runtime it built itself, so the NIFs have to be
  # rebuilt to match it — it does that with `zig cc`. Two of ours need
  # help getting through that, and `scripts/burrito-cc` is where the help
  # lives (one linker flag that waf spells the GNU way and zig's linker
  # refuses); the comment at the top of that file has the details.
  #
  # Bundling the *host's* runtime instead, and keeping the NIFs the host
  # already built, looks like the easier road and is a dead end: Burrito's
  # Linux wrapper embeds a musl shim it only fetches for its own runtime,
  # so the wrapper won't even compile without it.
  defp target(os, cpu) do
    [
      os: os,
      cpu: cpu,
      nif_env: [
        {"CC", Path.expand("scripts/burrito-cc", __DIR__)},
        {"BURRITO_CC_TARGET", zig_triple(os, cpu)}
      ]
    ]
  end

  defp zig_triple(:darwin, cpu), do: "#{cpu}-macos"
  defp zig_triple(os, cpu), do: "#{cpu}-#{os}"

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
      {:ecto_sqlite3, "~> 0.24"},
      {:garnish, "~> 0.3"},
      # Packages a release into one self-contained executable per OS, so
      # somebody can run this without installing Elixir or Erlang.
      # Build-time only: nothing in `lib/` calls it.
      {:burrito, "~> 1.6", runtime: false}
    ]
  end
end
