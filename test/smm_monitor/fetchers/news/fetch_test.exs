defmodule SmmMonitor.Fetchers.News.FetchTest do
  @moduledoc """
  The whole news fetch path, against a stub transport. No network.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.News
  alias SmmMonitor.NewsStub

  @now_ms DateTime.to_unix(~U[2026-11-12 12:00:00Z], :millisecond)

  @rss "https://opsledger.example/feed/"
  @atom "https://saasbriefing.example/atom.xml"
  @rdf "https://journal.example/rss"

  describe "your feeds" do
    test "items that name the brand, from every kind of feed" do
      NewsStub.install(%{
        "opsledger" => NewsStub.feed("rss2"),
        "saasbriefing" => NewsStub.feed("atom"),
        "journal" => NewsStub.feed("rdf")
      })

      assert {:ok, mentions, _state} = News.fetch(context(feeds: [@rss, @atom, @rdf]), nil)

      assert mentions |> Enum.map(& &1.url) |> Enum.sort() == [
               "https://journal.example/acme-office",
               "https://opsledger.example/2026/11/acme-prices",
               "https://opsledger.example/2026/11/ten-tools",
               "https://saasbriefing.example/acme-free-tier",
               "https://saasbriefing.example/globex-ceo"
             ]

      assert Enum.all?(mentions, &(&1.platform == :news and String.starts_with?(&1.id, "news-")))
    end

    test "a mention reads well: who, what, when" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {:ok, mentions, _state} = News.fetch(context(feeds: [@rss]), nil)
      mention = Enum.find(mentions, &(&1.url =~ "acme-prices"))

      assert mention.author == "Dana Lee (The Ops Ledger)"

      assert mention.text ==
               "Acme raises prices for small teams — Acme’s new plans start at $12 a seat."

      assert mention.timestamp == ~U[2026-11-12 09:30:00Z]
    end

    test "items older than a day, or not about the brand, are left out" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {:ok, mentions, _state} = News.fetch(context(feeds: [@rss]), nil)
      urls = Enum.map(mentions, & &1.url)

      refute Enum.any?(urls, &(&1 =~ "acme-review"))
      refute Enum.any?(urls, &(&1 =~ "/other"))
    end

    test "whole words only, as on every other platform" do
      body = rss([item("Acmeville fair opens", "a1"), item("Acme at the fair", "a2")])
      NewsStub.install(%{"opsledger" => NewsStub.ok(body)})

      {:ok, mentions, _state} = News.fetch(context(feeds: [@rss]), nil)
      assert [%{text: "Acme at the fair"}] = mentions
    end

    test "a feed is fetched once a poll, however many clients there are" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {:ok, acme, state} = News.fetch(context(feeds: [@rss]), nil)
      {:ok, globex, _state} = News.fetch(context(feeds: [@rss], client: globex()), state)

      assert length(NewsStub.requests_to("opsledger")) == 1
      assert length(acme) == 2
      assert [%{url: "https://opsledger.example/2026/11/ten-tools"}] = globex
    end

    test "the next poll fetches again" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {:ok, _mentions, state} = News.fetch(context(feeds: [@rss]), nil)
      {:ok, _mentions, _state} = News.fetch(context(feeds: [@rss], poll_count: 2), state)

      assert length(NewsStub.requests_to("opsledger")) == 2
    end

    test "a client is sent an item once" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {:ok, [_one, _two], state} = News.fetch(context(feeds: [@rss]), nil)
      {:ok, [], state} = News.fetch(context(feeds: [@rss], poll_count: 2), state)

      # A second client still gets its own first look.
      {:ok, [_globex], _state} =
        News.fetch(context(feeds: [@rss], client: globex(), poll_count: 2), state)
    end

    test "a new item on a later poll is sent" do
      first = rss([item("Acme one", "1")])
      second = rss([item("Acme two", "2"), item("Acme one", "1")])
      NewsStub.install(%{"opsledger" => [NewsStub.ok(first), NewsStub.ok(second)]})

      {:ok, [%{text: "Acme one"}], state} = News.fetch(context(feeds: [@rss]), nil)

      {:ok, [%{text: "Acme two"}], _state} =
        News.fetch(context(feeds: [@rss], poll_count: 2), state)
    end

    test "an undated item is old on the first read and new after it" do
      first = rss([undated("Acme undated old", "u1")])
      second = rss([undated("Acme undated new", "u2"), undated("Acme undated old", "u1")])

      NewsStub.install(%{
        "opsledger" => [NewsStub.ok(first), NewsStub.ok(second), NewsStub.ok(second)]
      })

      {:ok, [], state} = News.fetch(context(feeds: [@rss]), nil)
      {:ok, [new], state} = News.fetch(context(feeds: [@rss], poll_count: 2), state)
      {:ok, [], _state} = News.fetch(context(feeds: [@rss], poll_count: 3), state)

      assert new.text == "Acme undated new"
      assert new.timestamp == ~U[2026-11-12 12:00:00Z]
    end

    test "a date in the future is read as now" do
      body =
        rss([
          "<item><title>Acme tomorrow</title><guid>f1</guid>" <>
            "<pubDate>Fri, 13 Nov 2026 12:00:00 GMT</pubDate></item>"
        ])

      NewsStub.install(%{"opsledger" => NewsStub.ok(body)})

      {:ok, [mention], _state} = News.fetch(context(feeds: [@rss]), nil)
      assert mention.timestamp == ~U[2026-11-12 12:00:00Z]
    end

    test "with no brand terms, nothing is matched" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      client = %SmmMonitor.Client{id: "empty", name: "Empty", keywords: []}
      assert {:ok, [], _state} = News.fetch(context(feeds: [@rss], client: client), nil)
    end

    test "a feed taken out of the list is forgotten" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2"), "journal" => NewsStub.feed("rdf")})

      {:ok, _mentions, state} = News.fetch(context(feeds: [@rss, @rdf]), nil)
      {:ok, _mentions, state} = News.fetch(context(feeds: [@rdf], poll_count: 2), state)

      assert Map.keys(state.feeds) == [@rdf]
    end
  end

  describe "politeness" do
    test "sends back the validators, and a 304 costs nothing" do
      NewsStub.install(%{
        "opsledger" => [
          NewsStub.feed("rss2", [
            {"etag", ~s(W/"v1")},
            {"last-modified", "Thu, 12 Nov 2026 11:00:00 GMT"}
          ]),
          NewsStub.status(304)
        ]
      })

      {:ok, [_one, _two], state} = News.fetch(context(feeds: [@rss]), nil)
      {:ok, [], state} = News.fetch(context(feeds: [@rss], poll_count: 2), state)

      first = NewsStub.headers_of("opsledger", 1)
      second = NewsStub.headers_of("opsledger", 2)

      refute Map.has_key?(first, "if-none-match")
      assert second["if-none-match"] == ~s(W/"v1")
      assert second["if-modified-since"] == "Thu, 12 Nov 2026 11:00:00 GMT"

      # The items survive a 304, so a new client still sees them.
      {:ok, [_globex], _state} =
        News.fetch(context(feeds: [@rss], client: globex(), poll_count: 2), state)
    end

    test "asks for no compression and names the software, not the operator" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      News.fetch(context(feeds: [@rss]), nil)
      headers = NewsStub.headers_of("opsledger")

      assert headers["user-agent"] =~ ~r/\Asmm_monitor\/\S+ \(feed reader\)\z/
      refute Map.has_key?(headers, "accept-encoding")
      assert headers["accept"] =~ "application/rss+xml"
    end

    test "a failing feed waits 1, 2, 4 … polls before it is tried again" do
      NewsStub.install(%{"opsledger" => NewsStub.status(500)})

      state =
        Enum.reduce(1..8, nil, fn poll, state ->
          {_result, _mentions_or_reason, state} =
            with_quiet_log(fn -> News.fetch(context(feeds: [@rss], poll_count: poll), state) end)

          state
        end)

      # Tried on polls 1, 2, 4 and 8.
      assert length(NewsStub.requests_to("opsledger")) == 4
      assert state.feeds[@rss].failures == 4
    end

    test "a 429 is honoured for as long as it asks" do
      NewsStub.install(%{
        "opsledger" => [NewsStub.status(429, [{"retry-after", "1800"}]), NewsStub.feed("rss2")]
      })

      # Polls are 10 minutes apart: 30 minutes is 3 polls.
      state =
        Enum.reduce(1..4, nil, fn poll, state ->
          {_result, _value, state} =
            with_quiet_log(fn -> News.fetch(context(feeds: [@rss], poll_count: poll), state) end)

          state
        end)

      assert length(NewsStub.requests_to("opsledger")) == 2
      assert state.feeds[@rss].failures == 0
    end

    test "feeds are fetched side by side" do
      parent = self()

      slow = fn _request ->
        send(parent, {:started, self()})
        Process.sleep(100)
        NewsStub.feed("rdf")
      end

      urls = for n <- 1..4, do: "https://slow#{n}.example/rss"
      NewsStub.install(%{"slow" => slow})

      {micros, {:ok, _mentions, _state}} =
        :timer.tc(fn -> News.fetch(context(feeds: urls), nil) end)

      assert micros < 350_000
      assert length(NewsStub.requests_to("slow")) == 4
    end
  end

  describe "redirects" do
    test "are followed, to a relative or absolute address" do
      NewsStub.install(%{
        "opsledger.example/feed/" => NewsStub.status(302, [{"location", "/elsewhere"}]),
        "opsledger.example/elsewhere" =>
          NewsStub.status(301, [{"location", "https://new.example/feed"}]),
        "new.example" => NewsStub.feed("rss2")
      })

      assert {:ok, [_one, _two], _state} = News.fetch(context(feeds: [@rss]), nil)

      assert Enum.map(NewsStub.requests(), & &1.url) == [
               @rss,
               "https://opsledger.example/elsewhere",
               "https://new.example/feed"
             ]
    end

    test "a redirect to plain http is refused" do
      NewsStub.install(%{
        "opsledger" => NewsStub.status(301, [{"location", "http://opsledger.example/feed"}])
      })

      {result, log} = with_log(fn -> News.fetch(context(feeds: [@rss]), nil) end)

      assert {:error, {:feeds_unreachable, 1}, _state} = result
      assert log =~ "unsafe redirect"
      assert length(NewsStub.requests()) == 1
    end

    test "more than three hops is refused" do
      NewsStub.install(%{
        "opsledger" => fn request ->
          n = String.to_integer(request.url.query || "0")
          NewsStub.status(302, [{"location", "https://opsledger.example/feed/?#{n + 1}"}])
        end
      })

      {_result, log} = with_log(fn -> News.fetch(context(feeds: [@rss]), nil) end)

      assert log =~ "too many redirects"
      assert length(NewsStub.requests()) == 4
    end
  end

  describe "failures" do
    test "a body over the size limit is dropped" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      {result, log} =
        with_log(fn -> News.fetch(context(feeds: [@rss], max_body_bytes: 500), nil) end)

      assert {:error, {:feeds_unreachable, 1}, _state} = result
      assert log =~ "larger than the size limit"
    end

    test "a page that is not a feed fails that feed alone" do
      NewsStub.install(%{
        "opsledger" => NewsStub.ok("<html><body>Moved to our app!</body></html>"),
        "journal" => NewsStub.feed("rdf")
      })

      {result, log} = with_log(fn -> News.fetch(context(feeds: [@rss, @rdf]), nil) end)

      assert {:ok, [%{url: "https://journal.example/acme-office"}], _state} = result
      assert log =~ "not an RSS or Atom feed"
    end

    test "a network error fails that feed alone" do
      NewsStub.install(%{
        "opsledger" => %Req.TransportError{reason: :econnrefused},
        "journal" => NewsStub.feed("rdf")
      })

      {result, log} = with_log(fn -> News.fetch(context(feeds: [@rss, @rdf]), nil) end)

      assert {:ok, [_mention], _state} = result
      assert log =~ "network: :econnrefused"
    end

    test "every feed failing is an error the status line can show" do
      NewsStub.install(%{:any => NewsStub.status(404)})

      {result, _log} = with_log(fn -> News.fetch(context(feeds: [@rss, @rdf]), nil) end)
      assert {:error, {:feeds_unreachable, 2}, _state} = result
    end

    test "a failure is a warning once, then quiet" do
      NewsStub.install(%{
        "opsledger" => [NewsStub.status(500), NewsStub.status(500), NewsStub.feed("rss2")]
      })

      {{_e, _r, state}, first} = with_log(fn -> News.fetch(context(feeds: [@rss]), nil) end)

      {{_e, _r, state}, second} =
        with_log(fn -> News.fetch(context(feeds: [@rss], poll_count: 2), state) end)

      {{:ok, _m, state}, _third} =
        with_log(fn -> News.fetch(context(feeds: [@rss], poll_count: 4), state) end)

      assert first =~ "[warning]" and first =~ "HTTP 500"
      refute second =~ "[warning]"
      assert state.feeds[@rss].failures == 0
    end

    test "the logs name the feed by host and path, never its query" do
      url = "https://opsledger.example/feed/?key=SECRET-123"
      NewsStub.install(%{"opsledger" => NewsStub.status(500)})

      {_result, log} = with_log(fn -> News.fetch(context(feeds: [url]), nil) end)

      assert log =~ "opsledger.example/feed/"
      refute log =~ "SECRET-123"
    end
  end

  describe "Google News search" do
    test "is off unless switched on" do
      NewsStub.install(%{"opsledger" => NewsStub.feed("rss2")})

      News.fetch(context(feeds: [@rss]), nil)
      refute NewsStub.requested?("news.google.com")
    end

    test "searches the exact phrase from the last day, in the chosen edition" do
      NewsStub.install(%{"news.google.com" => NewsStub.feed("google_news")})

      News.fetch(context(search: :google, edition: "en-GB"), nil)

      assert [url] = NewsStub.requests_to("news.google.com")
      %URI{host: "news.google.com", path: "/rss/search", query: query} = URI.parse(url)

      assert URI.decode_query(query) == %{
               "q" => ~s("acme" when:1d),
               "hl" => "en-GB",
               "gl" => "GB",
               "ceid" => "GB:en"
             }
    end

    test "a headline without the publisher, who is the author" do
      NewsStub.install(%{"news.google.com" => NewsStub.feed("google_news")})

      {:ok, mentions, _state} = News.fetch(context(search: :google), nil)

      assert [first, second] = Enum.sort_by(mentions, & &1.timestamp, {:desc, DateTime})
      assert first.text == "Acme shares jump after earnings"
      assert first.author == "Martech Weekly"
      assert first.url == "https://news.google.com/rss/articles/CBMiAAA1?oc=5"
      assert second.author == "Growth Desk"
    end

    test "one search per brand term, at most five" do
      NewsStub.install(%{"news.google.com" => NewsStub.feed("google_news")})
      terms = ~w(acme globex initech umbrella hooli piedpiper)
      client = %SmmMonitor.Client{id: "many", name: "Many", keywords: terms}

      {:ok, mentions, _state} = News.fetch(context(search: :google, client: client), nil)

      assert length(NewsStub.requests_to("news.google.com")) == 5
      # The same story found twice is one mention.
      assert length(mentions) == 2
    end

    test "a 429 pauses the search; your feeds carry on" do
      NewsStub.install(%{
        "news.google.com" => [NewsStub.status(429), NewsStub.feed("google_news")],
        "opsledger" => NewsStub.feed("rss2")
      })

      {{:ok, mentions, state}, log} =
        with_log(fn -> News.fetch(context(feeds: [@rss], search: :google), nil) end)

      assert length(mentions) == 2
      assert log =~ "Google News is limiting requests; search pauses for 30 min"

      # Ten minutes on: still paused.
      later =
        context(
          feeds: [@rss],
          search: :google,
          poll_count: 2,
          clock: fn -> @now_ms + :timer.minutes(10) end
        )

      {:ok, _mentions, state} = News.fetch(later, state)
      assert length(NewsStub.requests_to("news.google.com")) == 1

      # Half an hour on: searching again.
      later =
        context(
          feeds: [@rss],
          search: :google,
          poll_count: 4,
          clock: fn -> @now_ms + :timer.minutes(31) end
        )

      {:ok, mentions, _state} = News.fetch(later, state)
      assert length(NewsStub.requests_to("news.google.com")) == 2
      assert Enum.any?(mentions, &(&1.author == "Martech Weekly"))
    end

    test "a failing search is no error while it is the only source" do
      NewsStub.install(%{"news.google.com" => NewsStub.status(500)})

      {result, log} = with_log(fn -> News.fetch(context(search: :google), nil) end)

      assert {:ok, [], _state} = result
      assert log =~ "Google News search failed (HTTP 500)"
    end
  end

  describe "ready?/1" do
    test "with a feed, or with search on" do
      assert News.ready?(context(feeds: [@rss]))
      assert News.ready?(context(search: :google))
      refute News.ready?(context([]))
    end

    test "feeds that may not be fetched do not count" do
      refute News.ready?(context(feeds: ["http://plain.example/feed", "ftp://x.example/"]))
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp context(overrides) do
    {client, overrides} = Keyword.pop(overrides, :client, acme())
    {poll_count, overrides} = Keyword.pop(overrides, :poll_count, 1)

    %{
      platform: :news,
      client: client,
      keywords: client.keywords,
      subreddits: [],
      credentials: [],
      opts:
        [feeds: [], search: :off, req_options: NewsStub.req_options(), clock: fn -> @now_ms end] ++
          overrides,
      poll_count: poll_count,
      interval_ms: :timer.minutes(10)
    }
    |> then(fn context -> %{context | opts: dedupe(context.opts)} end)
  end

  # Later options win, as Keyword.merge would have it.
  defp dedupe(opts), do: opts |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()

  defp acme, do: %SmmMonitor.Client{id: "acme", name: "Acme", keywords: ["acme"]}
  defp globex, do: %SmmMonitor.Client{id: "globex", name: "Globex", keywords: ["globex"]}

  defp with_quiet_log(fun) do
    {result, _log} = with_log(fun)
    result
  end

  defp rss(items) do
    ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>The Ops Ledger</title>) <>
      ~s(<link>https://opsledger.example/</link>) <> Enum.join(items) <> "</channel></rss>"
  end

  defp item(title, guid) do
    "<item><title>#{title}</title><guid>#{guid}</guid>" <>
      "<pubDate>Thu, 12 Nov 2026 11:00:00 GMT</pubDate></item>"
  end

  defp undated(title, guid), do: "<item><title>#{title}</title><guid>#{guid}</guid></item>"
end
