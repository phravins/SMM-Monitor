import Config

# Runtime configuration. This file runs on every boot (including from a
# release), which makes it the right place to read environment variables.
#
# Nothing here is required: with no env vars set the app boots, collects
# nothing, and says NOT CONNECTED until keys are entered in the setup
# wizard or supplied below. `SMM_DEMO=1` shows invented demo data instead.

defmodule SmmMonitor.RuntimeConfig do
  @moduledoc false

  def bool(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.downcase(value) in ~w(1 true yes on)
    end
  end

  # A typo in an env file should say which variable is wrong, not crash
  # boot with a bare ArgumentError from deep inside String.to_integer.
  def integer(var, default) do
    case System.get_env(var) do
      nil ->
        default

      value ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> n
          _other -> raise ArgumentError, "#{var} must be a whole number, got #{inspect(value)}"
        end
    end
  end

  def integer_or_nil(var), do: if(System.get_env(var), do: integer(var, nil))

  @doc """
  Reads a webhook URL, refusing anything that is not `https://host/...`.

  The URL is a credential (anyone holding it can post to the channel) and
  the alert payload carries client names, so it must never go out in
  clear text or to something that is not a host.
  """
  def https_url_or_nil(var) do
    case System.get_env(var) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case URI.new(String.trim(value)) do
          {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
            String.trim(value)

          _other ->
            raise ArgumentError, "#{var} must be an https:// URL"
        end
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
      nil ->
        default

      value ->
        case Float.parse(String.trim(value)) do
          {n, ""} -> n
          _other -> raise ArgumentError, "#{var} must be a number, got #{inspect(value)}"
        end
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

# Demo data is now something you ask for, not what you get.
#
# This used to default to true, so a fresh install filled itself with
# invented posts and said MOCK DATA in the corner. People read the
# dashboard, not the corner. The invented mentions went into the same
# database as real ones and skewed the trends, the alerts and every
# report exported afterwards.
#
# So the default is off: without credentials the app collects nothing
# and says so. `SMM_DEMO=1` (or the older `SMM_MOCK_MODE=true`) asks for
# the invented data back - useful for a demo or a screenshot, and now a
# deliberate choice. The setup wizard's "skip and watch demo data" sets
# it too, which is a person choosing it with their eyes open.
config :smm_monitor,
  # The test suite's only data source is fixtures - no test may call a
  # real API - so it keeps the old default. runtime.exs runs after
  # config/test.exs, so this is the only place that can decide it.
  mock_mode: RC.bool("SMM_DEMO", RC.bool("SMM_MOCK_MODE", config_env() == :test)),
  keywords: RC.list("SMM_KEYWORDS", ["realoffice", "real office"]),
  poll_interval_ms: RC.integer("SMM_POLL_INTERVAL_MS", 30_000),
  max_mentions: RC.integer("SMM_MAX_MENTIONS", 2_000),
  # `SMM_TUI=1 mix run --no-halt` starts the dashboard from the app
  # itself. The downloaded binary defaults to showing it: that is the
  # whole reason somebody ran it. Everything else stays headless, so the
  # test suite and `mix run` never fight the terminal for stdout.
  start_tui: RC.bool("SMM_TUI", System.get_env("__BURRITO") == "1")

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

# Alerting. The *thresholds* are per client and edited from the clients
# screen — there is deliberately no env var for them, since a single
# global threshold is the thing this replaced. What is left here is the
# on/off switch, the shared Slack webhook, and how far back the volume
# baseline looks.
config :smm_monitor,
  alerts_enabled: RC.bool("SMM_ALERTS_ENABLED", true),
  alert_baseline_days: RC.integer("SMM_ALERT_BASELINE_DAYS", 7)

if webhook = RC.https_url_or_nil("SMM_ALERT_WEBHOOK_URL") do
  config :smm_monitor, alert_webhook_url: webhook
end

# Weekly client reports, written unprompted to the reports directory.
# Off by default; see the README for what they contain.
config :smm_monitor,
  weekly_reports_enabled: RC.bool("SMM_WEEKLY_REPORTS", false),
  weekly_report_day: RC.integer("SMM_WEEKLY_REPORT_DAY", 1),
  weekly_report_hour: RC.integer("SMM_WEEKLY_REPORT_HOUR", 7)

if dir = System.get_env("SMM_REPORTS_DIR") do
  config :smm_monitor, reports_dir: dir
end

# Remote dashboard access over SSH. Off unless explicitly enabled, and
# listening on localhost only unless SMM_SSH_BIND says otherwise (reach it
# through a VPN or `ssh -L`, or set 0.0.0.0 deliberately).
config :smm_monitor,
  ssh_enabled: RC.bool("SMM_SSH_ENABLED", false),
  ssh_port: RC.integer("SMM_SSH_PORT", 2222),
  ssh_bind: System.get_env("SMM_SSH_BIND", "127.0.0.1")

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
# Unset (nil) means "inherit SMM_DEMO / SMM_MOCK_MODE", which is off: a
# platform with credentials collects live data, one without collects
# nothing. Setting one of these to `true` forces demo data for it.
config :smm_monitor, :mock_platforms,
  reddit: RC.bool_or_nil("SMM_MOCK_REDDIT"),
  youtube: RC.bool_or_nil("SMM_MOCK_YOUTUBE"),
  twitter: RC.bool_or_nil("SMM_MOCK_TWITTER"),
  instagram: RC.bool_or_nil("SMM_MOCK_INSTAGRAM")

# YouTube polls on its own schedule because of the API's daily quota.
# See the README for the arithmetic behind picking a value.
if interval_ms = RC.integer_or_nil("SMM_YOUTUBE_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, youtube: [interval_ms: interval_ms]
end

if budget = RC.integer_or_nil("SMM_YOUTUBE_DAILY_QUOTA_BUDGET") do
  config :smm_monitor, SmmMonitor.Fetchers.YouTube, daily_quota_budget: budget
end

# Twitter/X. The monthly post cap is the limit that ends a month early
# and it differs by plan, so the default is deliberately low. See README.
if budget = RC.integer_or_nil("SMM_TWITTER_MONTHLY_POST_BUDGET") do
  config :smm_monitor, SmmMonitor.Fetchers.Twitter, monthly_post_budget: budget
end

if cycle_day = RC.integer_or_nil("SMM_TWITTER_BILLING_CYCLE_DAY") do
  config :smm_monitor, SmmMonitor.Fetchers.Twitter, billing_cycle_day: cycle_day
end

if interval_ms = RC.integer_or_nil("SMM_TWITTER_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, twitter: [interval_ms: interval_ms]
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

if interval_ms = RC.integer_or_nil("SMM_INSTAGRAM_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, instagram: [interval_ms: interval_ms]
end

# Which subreddits the Reddit fetcher watches. Comma-separated; an empty
# value searches all of Reddit.
if subreddits = System.get_env("SMM_REDDIT_SUBREDDITS") do
  config :smm_monitor, SmmMonitor.Fetchers.Reddit,
    subreddits:
      subreddits |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# API credentials. Read from the environment, never committed. See
# docs/platforms.md. Keys typed into the setup wizard are stored in
# settings.json instead and merged in at boot; a value set here wins.
credentials = [
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
]

config :smm_monitor, :credentials, credentials

# Which of those came from the environment. The wizard may replace a key
# it saved itself, but never one an operator pinned in the env file.
# REDDIT_USER_AGENT has a default, so it only counts when actually set.
config :smm_monitor,
  env_credentials:
    for(
      {platform, fields} <- credentials,
      {field, value} <- fields,
      is_binary(value) and String.trim(value) != "",
      not (platform == :reddit and field == :user_agent and
             is_nil(System.get_env("REDDIT_USER_AGENT"))),
      do: {platform, field}
    )
