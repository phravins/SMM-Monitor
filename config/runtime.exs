import Config

# Runtime configuration. This file runs on every boot (including from a
# release), which makes it the right place to read environment variables.
#
# Nothing here is required: with no env vars set the app boots in mock mode
# and shows fixture data, which is what you want for a demo or for review.

defmodule SmmMonitor.RuntimeConfig do
  @moduledoc false

  def bool(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.downcase(value) in ~w(1 true yes on)
    end
  end

  def integer(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  @doc """
  Reads a boolean env var, returning `nil` when it is unset.

  `nil` means "no opinion", which lets a per-platform mock flag inherit
  the global `SMM_MOCK_MODE` rather than silently overriding it.
  """
  def bool_or_nil(var) do
    case System.get_env(var) do
      nil -> nil
      value -> String.downcase(value) in ~w(1 true yes on)
    end
  end

  def float(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.to_float(value)
    end
  end

  def list(var, default) do
    case System.get_env(var) do
      nil ->
        default

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end

alias SmmMonitor.RuntimeConfig, as: RC

# `SMM_MOCK_MODE=false` switches the fetchers over to the real HTTP calls.
# Any platform missing credentials falls back to mock data on its own, so
# flipping this off never takes the dashboard down.
config :smm_monitor,
  mock_mode: RC.bool("SMM_MOCK_MODE", true),
  keywords: RC.list("SMM_KEYWORDS", ["realoffice", "real office"]),
  poll_interval_ms: RC.integer("SMM_POLL_INTERVAL_MS", 30_000),
  max_mentions: RC.integer("SMM_MAX_MENTIONS", 2_000),
  # `SMM_TUI=1 mix run --no-halt` starts the dashboard from the app itself.
  start_tui: RC.bool("SMM_TUI", false)

# Where collected mentions are stored, and how long they are kept.
#
# Guarded on the environment because runtime.exs runs in *every* env,
# including test: without this it overrides config/test.exs and points the
# suite at the operator's real mention history.
if config_env() != :test do
  config :smm_monitor, SmmMonitor.Repo,
    database: System.get_env("SMM_DB_PATH") || SmmMonitor.Persistence.Paths.default_database()
end

config :smm_monitor, db_retention_days: RC.integer("SMM_RETENTION_DAYS", 30)

config :smm_monitor, history_limit: RC.integer("SMM_HISTORY_LIMIT", 200)

# Alerting on spikes in negative sentiment.
config :smm_monitor,
  alerts_enabled: RC.bool("SMM_ALERTS_ENABLED", true),
  alert_window_ms: RC.integer("SMM_ALERT_WINDOW_MS", 3_600_000),
  alert_baseline_days: RC.integer("SMM_ALERT_BASELINE_DAYS", 7),
  alert_cooldown_ms: RC.integer("SMM_ALERT_COOLDOWN_MS", 3_600_000)

if webhook = System.get_env("SMM_ALERT_WEBHOOK_URL") do
  config :smm_monitor, alert_webhook_url: webhook
end

# Thresholds, for tuning without a code change.
config :smm_monitor, :alerts,
  ratio: RC.float("SMM_ALERT_RATIO", 3.0),
  floor: RC.integer("SMM_ALERT_FLOOR", 5),
  warmup_ms: RC.integer("SMM_ALERT_WARMUP_MS", 86_400_000),
  critical_ratio: RC.float("SMM_ALERT_CRITICAL_RATIO", 6.0)

# Remote dashboard access over SSH. Off unless explicitly enabled.
config :smm_monitor,
  ssh_enabled: RC.bool("SMM_SSH_ENABLED", false),
  ssh_port: RC.integer("SMM_SSH_PORT", 2222)

if authorized_keys = System.get_env("SMM_SSH_AUTHORIZED_KEYS") do
  config :smm_monitor, ssh_authorized_keys: authorized_keys
end

if host_key_dir = System.get_env("SMM_SSH_HOST_KEY_DIR") do
  config :smm_monitor, ssh_host_key_dir: host_key_dir
end

# Per-platform overrides of the global mock switch. All four platforms
# have live implementations now, so `SMM_MOCK_<PLATFORM>=false` puts that
# one on live data independently of the others.
#
# Unset (nil) means "inherit SMM_MOCK_MODE", so the out-of-the-box
# experience is still fully mocked.
config :smm_monitor, :mock_platforms,
  reddit: RC.bool_or_nil("SMM_MOCK_REDDIT"),
  youtube: RC.bool_or_nil("SMM_MOCK_YOUTUBE"),
  twitter: RC.bool_or_nil("SMM_MOCK_TWITTER"),
  instagram: RC.bool_or_nil("SMM_MOCK_INSTAGRAM")

# YouTube polls on its own schedule because of the API's daily quota.
# See the README for the arithmetic behind picking a value.
if interval_ms = System.get_env("SMM_YOUTUBE_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, youtube: [interval_ms: String.to_integer(interval_ms)]
end

if budget = System.get_env("SMM_YOUTUBE_DAILY_QUOTA_BUDGET") do
  config :smm_monitor, SmmMonitor.Fetchers.YouTube, daily_quota_budget: String.to_integer(budget)
end

# Twitter/X. The monthly post cap is the limit that ends a month early
# and it differs by plan, so the default is deliberately low. See README.
if budget = System.get_env("SMM_TWITTER_MONTHLY_POST_BUDGET") do
  config :smm_monitor, SmmMonitor.Fetchers.Twitter, monthly_post_budget: String.to_integer(budget)
end

if cycle_day = System.get_env("SMM_TWITTER_BILLING_CYCLE_DAY") do
  config :smm_monitor, SmmMonitor.Fetchers.Twitter, billing_cycle_day: String.to_integer(cycle_day)
end

if interval_ms = System.get_env("SMM_TWITTER_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, twitter: [interval_ms: String.to_integer(interval_ms)]
end

# Instagram. Which of the three account-scoped sources to poll — the
# Graph API has no keyword search, so there is nothing broader to enable.
# See the README for what each one can and cannot see.
if sources = System.get_env("SMM_INSTAGRAM_SOURCES") do
  config :smm_monitor, SmmMonitor.Fetchers.Instagram,
    sources: sources |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# Hashtags to search, if the :hashtag source is enabled. Defaults to the
# brand keywords with spaces stripped. Meta allows 30 unique hashtags per
# rolling 7 days, so keep this list short and stable.
if hashtags = System.get_env("SMM_INSTAGRAM_HASHTAGS") do
  config :smm_monitor, SmmMonitor.Fetchers.Instagram,
    hashtags: hashtags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

if interval_ms = System.get_env("SMM_INSTAGRAM_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, instagram: [interval_ms: String.to_integer(interval_ms)]
end

# Which subreddits the Reddit fetcher watches. Comma-separated; an empty
# value searches all of Reddit.
if subreddits = System.get_env("SMM_REDDIT_SUBREDDITS") do
  config :smm_monitor, SmmMonitor.Fetchers.Reddit,
    subreddits:
      subreddits |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# API credentials. Read from the environment, never committed. See README.
config :smm_monitor, :credentials,
  reddit: [
    client_id: System.get_env("REDDIT_CLIENT_ID"),
    client_secret: System.get_env("REDDIT_CLIENT_SECRET"),
    user_agent: System.get_env("REDDIT_USER_AGENT", "smm_monitor/0.1 (RealOffice)")
  ],
  youtube: [
    api_key: System.get_env("YOUTUBE_API_KEY")
  ],
  twitter: [
    bearer_token: System.get_env("TWITTER_BEARER_TOKEN")
  ],
  instagram: [
    access_token: System.get_env("INSTAGRAM_ACCESS_TOKEN"),
    # INSTAGRAM_USER_ID is the older name for the same value; both are
    # accepted so an existing env file keeps working.
    business_account_id:
      System.get_env("INSTAGRAM_BUSINESS_ACCOUNT_ID") || System.get_env("INSTAGRAM_USER_ID")
  ]
