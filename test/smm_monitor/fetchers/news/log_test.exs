defmodule SmmMonitor.Fetchers.News.LogTest do
  @moduledoc """
  What the operator reads when a feed moves or comes back.

  These messages are `:info`, below the suite's level, so this file
  raises the level and cannot be async.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.News
  alias SmmMonitor.NewsStub

  @now_ms DateTime.to_unix(~U[2026-11-12 12:00:00Z], :millisecond)
  @rss "https://opsledger.example/feed/"

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "a permanent move is reported once, with what to do" do
    NewsStub.install(%{
      "opsledger.example/feed/" => NewsStub.status(301, [{"location", "https://new.example/feed"}]),
      "new.example" => NewsStub.feed("rss2")
    })

    {{:ok, _mentions, state}, log} = with_log(fn -> News.fetch(context(1), nil) end)
    {{:ok, _mentions, _state}, again} = with_log(fn -> News.fetch(context(2), state) end)

    assert log =~ "opsledger.example/feed/ has moved permanently to new.example/feed"
    assert log =~ "update SMM_NEWS_FEEDS"
    refute again =~ "moved permanently"
  end

  test "a temporary move is followed without a word" do
    NewsStub.install(%{
      "opsledger.example/feed/" => NewsStub.status(302, [{"location", "https://new.example/feed"}]),
      "new.example" => NewsStub.feed("rss2")
    })

    {{:ok, [_one, _two], _state}, log} = with_log(fn -> News.fetch(context(1), nil) end)
    refute log =~ "moved"
  end

  test "a feed that comes back says so" do
    NewsStub.install(%{"opsledger" => [NewsStub.status(500), NewsStub.feed("rss2")]})

    {{:error, _reason, state}, _log} = with_log(fn -> News.fetch(context(1), nil) end)
    {{:ok, _mentions, _state}, log} = with_log(fn -> News.fetch(context(2), state) end)

    assert log =~ "news: opsledger.example/feed/ is reachable again"
  end

  test "Google News search recovering says so" do
    NewsStub.install(%{
      "news.google.com" => [NewsStub.status(500), NewsStub.feed("google_news")]
    })

    {{:ok, [], state}, _log} = with_log(fn -> News.fetch(context(1, search: :google), nil) end)

    {{:ok, [_one, _two], _state}, log} =
      with_log(fn -> News.fetch(context(2, search: :google), state) end)

    assert log =~ "Google News search works again"
  end

  defp context(poll_count, opts \\ [feeds: [@rss]]) do
    client = %SmmMonitor.Client{id: "acme", name: "Acme", keywords: ["acme"]}

    %{
      platform: :news,
      client: client,
      keywords: client.keywords,
      subreddits: [],
      credentials: [],
      opts: [req_options: NewsStub.req_options(), clock: fn -> @now_ms end] ++ opts,
      poll_count: poll_count,
      interval_ms: :timer.minutes(10)
    }
  end
end
