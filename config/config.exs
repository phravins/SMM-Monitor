import Config

# Compile-time defaults. Anything that depends on the deployment environment
# (API keys, poll intervals, mock mode) is overridden in `runtime.exs`.
config :smm_monitor,
  # Brand terms we search for across every platform.
  keywords: ["realoffice", "real office"],
  # How often a fetcher with no `interval_ms` of its own polls: Reddit,
  # whose subreddit listings this keeps about 15 seconds behind.
  poll_interval_ms: 15_000,
  # Sliding window used by the dashboard's counters.
  window_ms: :timer.hours(24),
  # Mentions older than this are pruned from ETS.
  retention_ms: :timer.hours(48),
  # Hard cap on rows kept in ETS, so a chatty platform can't eat all memory.
  max_mentions: 2_000,
  # Demo (invented) data is off: a platform with credentials collects live
  # data and one without collects nothing. runtime.exs turns it on for the
  # test suite and when SMM_DEMO=1 is set.
  mock_mode: false,
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
  start_tui: false,
  # Watch each client for sentiment drops, volume spikes and watch
  # phrases. On by default; the thresholds themselves live on the client
  # (SmmMonitor.Client.AlertConfig), not here, because they differ by
  # brand.
  alerts_enabled: true,
  # How many days of same-hour history the volume baseline is drawn from.
  alert_baseline_days: 7,
  # Remote access over SSH is opt-in; see SMM_SSH_ENABLED in the README.
  ssh_enabled: false,
  # Unprivileged by default, so the app never needs root to bind.
  ssh_port: 2222,
  # Loopback only unless SMM_SSH_BIND says otherwise.
  ssh_bind: "127.0.0.1"

# One entry per platform worker. `module` implements SmmMonitor.Fetchers.Fetcher,
# or SmmMonitor.Fetchers.Stream for `kind: :stream` platforms.
# Adding a platform is a matter of writing the module and adding a line here.
config :smm_monitor, :platforms,
  reddit: [module: SmmMonitor.Fetchers.Reddit, enabled: true, opts: []],
  youtube: [
    module: SmmMonitor.Fetchers.YouTube,
    enabled: true,
    # Far slower than the other platforms on purpose: a YouTube search
    # costs 100 of the 10,000 free daily quota units, and the fetcher
    # stops for the day at the 8,000-unit budget. At 18 minutes that is
    # 80 searches a day, so collection runs around the clock instead of
    # going dark in the evening. See docs/platforms.md.
    interval_ms: :timer.minutes(18),
    opts: []
  ],
  twitter: [
    module: SmmMonitor.Fetchers.Twitter,
    enabled: true,
    # Slower than Reddit: recent search is bounded by a monthly post cap,
    # so polling every 30s would spend a month's worth in days.
    interval_ms: :timer.minutes(5),
    opts: []
  ],
  instagram: [
    module: SmmMonitor.Fetchers.Instagram,
    enabled: true,
    # Several requests per poll against Meta's hourly allowance, and the
    # edges it reads move slowly. Every 15 minutes is plenty.
    interval_ms: :timer.minutes(15),
    opts: []
  ],
  # Polled: Threads has no stream. Each poll searches every brand term,
  # against Meta's 2,200 searches a day. Every 5 minutes fits about
  # seven terms across all clients; see docs/platforms.md#threads.
  # Its tab appears once THREADS_ACCESS_TOKEN is set.
  threads: [
    module: SmmMonitor.Fetchers.Threads,
    enabled: true,
    tab: :when_on,
    interval_ms: :timer.minutes(5),
    opts: []
  ],
  # Not polled: one WebSocket that receives every new Bluesky post as it
  # is written. Collects nothing until SMM_BLUESKY_ENABLED=true.
  # Its tab appears once it is switched on (`tab: :when_on`).
  bluesky: [
    module: SmmMonitor.Fetchers.Bluesky,
    kind: :stream,
    enabled: true,
    tab: :when_on,
    opts: []
  ],
  # Not polled either: a bot on Discord's Gateway, reading the servers it
  # has been invited to. Collects nothing until DISCORD_BOT_TOKEN is set.
  discord: [
    module: SmmMonitor.Fetchers.Discord,
    kind: :stream,
    enabled: true,
    tab: :when_on,
    opts: []
  ],
  # Streamed as well: one Mastodon server's public timeline. Collects
  # nothing until MASTODON_INSTANCE and MASTODON_ACCESS_TOKEN are set.
  mastodon: [
    module: SmmMonitor.Fetchers.Mastodon,
    kind: :stream,
    enabled: true,
    tab: :when_on,
    opts: []
  ],
  # Polled: RSS and Atom feeds, and Google News search if switched on.
  # Every 10 minutes is as often as most publishers update their feeds,
  # and each fetch is conditional, so an unchanged feed costs a 304.
  # Its tab appears once SMM_NEWS_FEEDS or SMM_NEWS_SEARCH is set.
  news: [
    module: SmmMonitor.Fetchers.News,
    enabled: true,
    tab: :when_on,
    interval_ms: :timer.minutes(10),
    opts: []
  ]

# Which subreddits to watch is deployment-specific, so
# `SMM_REDDIT_SUBREDDITS` overrides this list at runtime (and each client
# can name its own). An empty list searches all of Reddit.
config :smm_monitor, SmmMonitor.Fetchers.Reddit,
  subreddits: ["smallbusiness", "marketing", "socialmedia", "Entrepreneur"],
  # A client's subreddits are read for new posts and, with this on, new
  # comments too: one more request per poll for every 50 subreddits.
  comments: true,
  # How often all of Reddit is searched for a client with no subreddits.
  # The subreddit listings follow the poll interval instead.
  search_interval_ms: 30_000,
  # Search results per request. Reddit caps a listing at 100.
  limit: 50,
  sort: "new",
  # How far back the search reaches: hour, day, week, month, year, all.
  # "day" keeps every result inside the 48h in-memory window, so a post
  # is never pruned and then re-fetched as if it were new.
  time_filter: "day"

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
