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
  # How many mentions per platform to restore from the database on boot,
  # so the dashboard isn't empty after a restart.
  history_limit: 200,
  # How long a mention is kept on disk. Distinct from :retention_ms above,
  # which governs the in-memory ETS window.
  db_retention_days: 30,
  # Whether the supervision tree starts the platform fetchers. Tests turn
  # this off so they can exercise the processing layer in isolation.
  start_fetchers: true,
  # The TUI is started by `mix smm.tui` / the escript, not by the app itself.
  start_tui: false

# One entry per platform worker. `module` implements SmmMonitor.Fetchers.Fetcher.
# Adding a platform is a matter of writing the module and adding a line here.
config :smm_monitor, :platforms,
  reddit: [module: SmmMonitor.Fetchers.Reddit, enabled: true, opts: []],
  youtube: [
    module: SmmMonitor.Fetchers.YouTube,
    enabled: true,
    # Far slower than the other platforms on purpose: a YouTube search
    # costs 100 of the 10,000 free daily quota units. See the README.
    interval_ms: :timer.minutes(5),
    opts: []
  ],
  twitter: [module: SmmMonitor.Fetchers.Twitter, enabled: true, opts: []],
  instagram: [module: SmmMonitor.Fetchers.Instagram, enabled: true, opts: []]

# Reddit is the one platform with a live implementation. Which subreddits
# to watch is deployment-specific, so `SMM_REDDIT_SUBREDDITS` overrides
# this list at runtime. An empty list searches all of Reddit.
config :smm_monitor, SmmMonitor.Fetchers.Reddit,
  subreddits: ["smallbusiness", "marketing", "socialmedia", "Entrepreneur"],
  # Items per request. Reddit caps a listing at 100.
  limit: 50,
  sort: "new",
  # How far back the search reaches: hour, day, week, month, year, all.
  time_filter: "week"

# YouTube's free tier is 10,000 quota units a day and a search costs 100,
# so the real ceiling is 100 searches a day. The budget below stops short
# of that, leaving room for anything else using the same key.
config :smm_monitor, SmmMonitor.Fetchers.YouTube,
  # Results per search. The API caps a page at 50.
  max_results: 25,
  # date | relevance | rating | title | viewCount
  order: "date",
  # Stop polling once this many units have been spent today.
  daily_quota_budget: 8_000,
  # Only consider videos published within this window.
  published_within_ms: :timer.hours(24)

config :smm_monitor, ecto_repos: [SmmMonitor.Repo]

# WAL lets the retention job delete while the writer inserts;
# synchronous = NORMAL avoids an fsync per transaction, which is the right
# trade for a log of social mentions — losing the last second of writes to
# a power cut costs nothing the next poll won't re-fetch.
config :smm_monitor, SmmMonitor.Repo,
  journal_mode: :wal,
  synchronous: :normal,
  # One writer, one reader on boot, one pruner: SQLite serialises writes
  # anyway, so a large pool would buy nothing.
  pool_size: 2,
  # Wait rather than failing immediately if another connection holds the
  # write lock.
  busy_timeout: 5_000,
  # Migrations are run by SmmMonitor.Persistence.Migrator at boot.
  priv: "priv/repo"

import_config "#{config_env()}.exs"
