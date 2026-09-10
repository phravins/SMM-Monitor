import Config

# Tests drive the processing layer directly; no fetchers, no TUI, no timers.
config :smm_monitor,
  # Never let a test write over the real runtime config file.
  config_file: "tmp/test_runtime_config.json",
  # Alerting is exercised by driving the GenServer directly, not on a
  # timer racing assertions.
  alerts_enabled: false,
  # Boot-loading history would fight tests that assert on an empty store.
  load_history_on_boot: false,
  # The repo still runs, so tests have a database; the writer and the
  # retention job are started per-test inside the sandbox instead of
  # writing from outside any test's ownership.
  persist_writes: false,
  start_fetchers: false,
  start_tui: false,
  mock_mode: true,
  poll_interval_ms: 60_000

# A throwaway database per test run, never the real one.
config :smm_monitor, SmmMonitor.Repo,
  database: "tmp/test_mentions.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning
