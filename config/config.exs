import Config

# Compile-time defaults. Anything that depends on the deployment environment
# (API keys, poll intervals, mock mode) is overridden in `runtime.exs`.
config :smm_monitor,
  # Brand terms we search for across every platform.
  keywords: ["realoffice", "real office"],
  # How often each fetcher polls its platform.
  poll_interval_ms: 30_000,
  # Sliding window used by the dashboard's counters.
  window_ms: :timer.hours(24),
  # Mentions older than this are pruned from ETS.
  retention_ms: :timer.hours(48),
  # Hard cap on rows kept in ETS, so a chatty platform can't eat all memory.
  max_mentions: 2_000,
  # Mock mode is the default so the tool runs with fake data out of the box.
  mock_mode: true,
  # Whether the supervision tree starts the platform fetchers. Tests turn
  # this off so they can exercise the processing layer in isolation.
  start_fetchers: true,
  # The TUI is started by `mix smm.tui` / the escript, not by the app itself.
  start_tui: false

# One entry per platform worker. `module` implements SmmMonitor.Fetchers.Fetcher.
# Adding a platform is a matter of writing the module and adding a line here.
config :smm_monitor, :platforms,
  reddit: [module: SmmMonitor.Fetchers.Reddit, enabled: true, opts: [subreddits: ["all"]]],
  youtube: [module: SmmMonitor.Fetchers.YouTube, enabled: true, opts: [max_results: 25]],
  twitter: [module: SmmMonitor.Fetchers.Twitter, enabled: true, opts: []],
  instagram: [module: SmmMonitor.Fetchers.Instagram, enabled: true, opts: []]

import_config "#{config_env()}.exs"
