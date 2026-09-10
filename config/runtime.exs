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
config :smm_monitor, SmmMonitor.Repo,
  database: System.get_env("SMM_DB_PATH") || SmmMonitor.Persistence.Paths.default_database()

config :smm_monitor, db_retention_days: RC.integer("SMM_RETENTION_DAYS", 30)

config :smm_monitor, history_limit: RC.integer("SMM_HISTORY_LIMIT", 200)

# Per-platform overrides of the global mock switch. Reddit and YouTube
# have live implementations, so `SMM_MOCK_REDDIT=false` and
# `SMM_MOCK_YOUTUBE=false` put those on live data while Twitter and
# Instagram stay on fixtures.
#
# Unset (nil) means "inherit SMM_MOCK_MODE", so the out-of-the-box
# experience is still fully mocked.
config :smm_monitor, :mock_platforms,
  reddit: RC.bool_or_nil("SMM_MOCK_REDDIT"),
  youtube: RC.bool_or_nil("SMM_MOCK_YOUTUBE")

# YouTube polls on its own schedule because of the API's daily quota.
# See the README for the arithmetic behind picking a value.
if interval_ms = System.get_env("SMM_YOUTUBE_POLL_INTERVAL_MS") do
  config :smm_monitor, :platforms, youtube: [interval_ms: String.to_integer(interval_ms)]
end

if budget = System.get_env("SMM_YOUTUBE_DAILY_QUOTA_BUDGET") do
  config :smm_monitor, SmmMonitor.Fetchers.YouTube, daily_quota_budget: String.to_integer(budget)
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
    user_id: System.get_env("INSTAGRAM_USER_ID")
  ]
