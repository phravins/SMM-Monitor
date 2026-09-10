import Config

# Tests drive the processing layer directly; no fetchers, no TUI, no timers.
config :smm_monitor,
  # Never let a test write over the real runtime config file.
  config_file: "tmp/test_runtime_config.json",
  start_fetchers: false,
  start_tui: false,
  mock_mode: true,
  poll_interval_ms: 60_000

config :logger, level: :warning
