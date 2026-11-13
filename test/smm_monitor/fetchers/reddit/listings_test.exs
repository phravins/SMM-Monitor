defmodule SmmMonitor.Fetchers.Reddit.ListingsTest do
  @moduledoc """
  Reading a client's subreddits: the newest posts and comments, matched
  here against the client's brand terms, shared between clients, and
  handed to each client once.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SmmMonitor.Fetchers.Reddit
  alias SmmMonitor.Fetchers.Reddit.{Auth, Listings, RateLimit, State}
  alias SmmMonitor.RedditStub

  doctest SmmMonitor.Fetchers.Reddit
  doctest SmmMonitor.Fetchers.Reddit.Listings

  @credentials [client_id: "id", client_secret: "secret", user_agent: "smm_monitor/test"]
  # The fixtures' items are from the minutes before this.
  @now_ms DateTime.to_unix(~U[2026-11-12 12:00:00Z], :millisecond)
  @empty %{"data" => %{"children" => [], "after" => nil}}

  setup_all do
    {:ok,
     new: "test/fixtures/reddit_new.json" |> File.read!() |> Jason.decode!(),
     comments: "test/fixtures/reddit_comments.json" |> File.read!() |> Jason.decode!()}
  end

  describe "reading a client's subreddits" do
    test "returns the new posts and comments that name a brand term", fixtures do
      install(fixtures)

      {:ok, mentions, _state} = Reddit.fetch(context("acme", ~w(marketing smallbusiness)), nil)

      # Not the post with no brand term, the deleted post, the removed
      # comment, or the post from three days ago.
      assert mentions |> Enum.map(& &1.id) |> Enum.sort() ==
               ["reddit-p1new", "reddit-p3new", "reddit-t1_c1hit"]

      post = Enum.find(mentions, &(&1.id == "reddit-p1new"))
      assert post.platform == :reddit
      assert post.author == "u/agency_amy"

      assert post.text ==
               "Anyone tried RealOffice for client reports? — Looking for something lighter than our current setup."

      assert post.url =~ ~r{\Ahttps://reddit\.com/r/marketing/comments/p1new/}
      assert post.timestamp == div(@now_ms, 1_000) - 120

      comment = Enum.find(mentions, &(&1.id == "reddit-t1_c1hit"))
      assert comment.author == "u/support_sam"
      assert comment.text == "RealOffice support replied within the hour, which surprised me."
      assert comment.url == "https://reddit.com/r/marketing/comments/p9zzz/a_thread/c1hit/"
    end

    test "a phrase term matches across the post body", fixtures do
      install(fixtures)

      {:ok, mentions, _state} =
        Reddit.fetch(context("acme", ~w(smallbusiness), keywords: ["real office"]), nil)

      assert Enum.map(mentions, & &1.id) == ["reddit-p3new"]
    end

    test "reads both listings for all the subreddits in one request each", fixtures do
      install(fixtures)

      Reddit.fetch(context("acme", ~w(Marketing r/smallbusiness)), nil)

      assert [{:get, new_url}] = RedditStub.requests_of(:new)
      assert [{:get, comments_url}] = RedditStub.requests_of(:comments)
      assert RedditStub.search_requests() == []

      assert new_url =~ "oauth.reddit.com/r/marketing+smallbusiness/new?"
      assert comments_url =~ "oauth.reddit.com/r/marketing+smallbusiness/comments?"
      assert RedditStub.query(new_url) == %{"limit" => "100", "raw_json" => "1"}
    end

    test "comments are left alone with comments: false", fixtures do
      install(fixtures)

      {:ok, mentions, _state} =
        Reddit.fetch(context("acme", ~w(marketing smallbusiness), comments: false), nil)

      assert RedditStub.requests_of(:comments) == []
      refute Enum.any?(mentions, &(&1.id == "reddit-t1_c1hit"))
    end

    test "the next poll hands over only what is new", fixtures do
      later =
        post("p6new", "marketing", "Switched to RealOffice today", 30)
        |> prepend(fixtures.new)

      RedditStub.install(
        token: RedditStub.token(),
        new: [
          RedditStub.listing(fixtures.new),
          RedditStub.listing(fixtures.new),
          RedditStub.listing(later)
        ],
        comments: RedditStub.listing(fixtures.comments)
      )

      context = context("acme", ~w(marketing smallbusiness))

      {:ok, [_, _, _], state} = Reddit.fetch(context, nil)
      assert {:ok, [], state} = Reddit.fetch(%{context | poll_count: 1}, state)

      assert {:ok, [%{id: "reddit-p6new"}], _state} =
               Reddit.fetch(%{context | poll_count: 2}, state)
    end

    test "names that are not subreddits never reach a request, and are warned about once",
         fixtures do
      install(fixtures)
      context = context("acme", ["marketing", "../../api/v1/me", "a b"])

      {{:ok, _mentions, state}, log} = with_log(fn -> Reddit.fetch(context, nil) end)

      {{:ok, _mentions, _state}, again} =
        with_log(fn -> Reddit.fetch(%{context | poll_count: 1}, state) end)

      assert [{:get, url}] = RedditStub.requests_of(:new) |> Enum.take(1)
      assert url =~ "/r/marketing/new"
      refute Enum.any?(RedditStub.requests(), fn {_method, url} -> url =~ "api/v1/me" end)

      assert log =~ ~s(ignoring "../../api/v1/me")
      assert log =~ ~s(ignoring "a b")
      refute again =~ "ignoring"
    end
  end

  describe "sharing the read between clients" do
    test "one read per poll covers every client's subreddits", fixtures do
      install(fixtures, serve: true)
      acme = context("acme", ~w(marketing))
      beta = context("beta", ~w(smallbusiness))

      # The first poll learns each client's subreddits as it reaches it.
      {:ok, _mentions, state} = Reddit.fetch(acme, nil)
      {:ok, _mentions, state} = Reddit.fetch(beta, state)
      assert length(RedditStub.requests_of(:new)) == 2

      # From then on the first client of a poll reads for both.
      {:ok, _mentions, state} = Reddit.fetch(%{acme | poll_count: 1}, state)
      {:ok, _mentions, _state} = Reddit.fetch(%{beta | poll_count: 1}, state)

      assert [_, _, {:get, url}] = RedditStub.requests_of(:new)
      assert url =~ "/r/marketing+smallbusiness/new"
    end

    test "each client gets only items from its own subreddits", fixtures do
      install(fixtures, serve: true)
      acme = context("acme", ~w(marketing))
      beta = context("beta", ~w(smallbusiness))

      {:ok, _mentions, state} = Reddit.fetch(acme, nil)
      {:ok, _mentions, state} = Reddit.fetch(beta, state)

      # Poll 1 reads both subreddits in acme's call; beta's items wait
      # in the buffer for beta, and acme sees none of them.
      RedditStub.install(
        token: RedditStub.token(),
        new:
          serve(post("p7new", "smallbusiness", "RealOffice pricing?", 10) |> prepend(fixtures.new)),
        comments: serve(fixtures.comments)
      )

      {:ok, acme_mentions, state} = Reddit.fetch(%{acme | poll_count: 1}, state)
      {:ok, beta_mentions, _state} = Reddit.fetch(%{beta | poll_count: 1}, state)

      assert acme_mentions == []
      assert Enum.map(beta_mentions, & &1.id) == ["reddit-p7new"]
    end

    test "a client that missed a poll catches up on the next", fixtures do
      RedditStub.install(
        token: RedditStub.token(),
        new: [RedditStub.listing(@empty), RedditStub.listing(fixtures.new)],
        comments: RedditStub.listing(@empty)
      )

      acme = context("acme", ~w(marketing smallbusiness))
      beta = context("beta", ~w(marketing smallbusiness))

      {:ok, [], state} = Reddit.fetch(acme, nil)
      {:ok, [], state} = Reddit.fetch(beta, state)

      # Poll 1 stops after acme (a rate limit, say); beta is not reached.
      {:ok, [_, _], state} = Reddit.fetch(%{acme | poll_count: 1}, state)

      # Poll 2 reads nothing new, and beta still gets what it missed.
      {:ok, [], state} = Reddit.fetch(%{acme | poll_count: 2}, state)
      assert {:ok, [_, _], _state} = Reddit.fetch(%{beta | poll_count: 2}, state)
    end
  end

  describe "gaps" do
    test "a full page of nothing but new items reads the next page, up to three" do
      pages = for page <- 1..5, do: full_page(page)

      RedditStub.install(
        token: RedditStub.token(),
        new: [RedditStub.listing(@empty) | Enum.map(pages, &RedditStub.listing/1)]
      )

      context = context("acme", ~w(marketing), comments: false)
      {:ok, [], state} = Reddit.fetch(context, nil)
      {:ok, mentions, _state} = Reddit.fetch(%{context | poll_count: 1}, state)

      assert [_primer, {:get, first}, {:get, second}, {:get, third}] = RedditStub.requests_of(:new)
      refute Map.has_key?(RedditStub.query(first), "after")
      assert RedditStub.query(second)["after"] == "t3_g1x99"
      assert RedditStub.query(third)["after"] == "t3_g2x99"
      assert length(mentions) == 300
    end

    test "the first read takes one page, however full" do
      RedditStub.install(token: RedditStub.token(), new: RedditStub.listing(full_page(1)))

      {:ok, mentions, _state} = Reddit.fetch(context("acme", ~w(marketing), comments: false), nil)

      assert length(RedditStub.requests_of(:new)) == 1
      assert length(mentions) == 100
    end
  end

  describe "failures" do
    test "a refused token is dropped and the next poll gets a new one", fixtures do
      RedditStub.install(
        token: RedditStub.token(),
        new: [RedditStub.error(401), RedditStub.listing(fixtures.new)],
        comments: RedditStub.listing(fixtures.comments)
      )

      context = context("acme", ~w(marketing smallbusiness))

      assert {:error, :unauthorized, state} = Reddit.fetch(context, nil)
      refute Auth.valid?(state.auth)

      assert {:ok, [_, _, _], _state} = Reddit.fetch(%{context | poll_count: 1}, state)
      assert length(RedditStub.token_requests()) == 2
    end

    test "a 429 becomes a backoff the worker can act on" do
      RedditStub.install(
        token: RedditStub.token(),
        new: RedditStub.error(429, RedditStub.rate_limit_headers("0.0", "100.0", "30"))
      )

      assert {:error, {:rate_limited, wait_ms}, _state} =
               Reddit.fetch(context("acme", ~w(marketing)), nil)

      assert wait_ms > 0
    end

    test "no request is spent when the quota is nearly gone" do
      RedditStub.install(token: RedditStub.token())

      exhausted = %{
        State.new()
        | rate_limit:
            RateLimit.observe(RateLimit.new(), RedditStub.rate_limit_headers("1.0", "99.0", "30"))
      }

      assert {:error, {:rate_limited, _ms}, _state} =
               Reddit.fetch(context("acme", ~w(marketing)), exhausted)

      assert RedditStub.requests() == []
    end

    test "a server error fails every client of that poll, and nothing is lost", fixtures do
      RedditStub.install(
        token: RedditStub.token(),
        new: [RedditStub.error(503), RedditStub.listing(fixtures.new)],
        comments: RedditStub.listing(fixtures.comments)
      )

      acme = context("acme", ~w(marketing smallbusiness))
      beta = context("beta", ~w(marketing))

      assert {:error, {:http_error, 503}, state} = Reddit.fetch(acme, nil)
      assert {:error, {:http_error, 503}, state} = Reddit.fetch(beta, state)
      # Beta was told about acme's failed read rather than trying again.
      assert length(RedditStub.requests_of(:new)) == 1

      assert {:ok, [_, _, _], state} = Reddit.fetch(%{acme | poll_count: 1}, state)
      assert {:ok, [_, _], _state} = Reddit.fetch(%{beta | poll_count: 1}, state)
    end

    test "a refused subreddit is found, skipped for an hour, and the rest still read", fixtures do
      refuse = fn url ->
        if url =~ "bannedsub", do: RedditStub.error(404), else: serve(fixtures.new).(url)
      end

      RedditStub.install(token: RedditStub.token(), new: refuse, comments: serve(fixtures.comments))

      context = context("acme", ~w(bannedsub marketing))

      {{:ok, mentions, state}, log} = with_log(fn -> Reddit.fetch(context, nil) end)

      assert mentions |> Enum.map(& &1.id) |> Enum.sort() == ["reddit-p1new", "reddit-t1_c1hit"]
      assert log =~ "r/bannedsub could not be read (HTTP 404)"
      assert log =~ "private, banned or misspelt"

      new_urls = Enum.map(RedditStub.requests_of(:new), fn {:get, url} -> URI.parse(url).path end)
      assert new_urls == ["/r/bannedsub+marketing/new", "/r/bannedsub/new", "/r/marketing/new"]

      # The next poll leaves it out.
      {:ok, _mentions, _state} = Reddit.fetch(%{context | poll_count: 1}, state)
      assert {:get, url} = List.last(RedditStub.requests_of(:new))
      assert URI.parse(url).path == "/r/marketing/new"
    end

    test "a redirect is a refusal, not something to follow", fixtures do
      RedditStub.install(
        token: RedditStub.token(),
        new:
          RedditStub.error(302, %{"location" => ["https://www.reddit.com/subreddits/search?q=x"]}),
        comments: RedditStub.listing(fixtures.comments)
      )

      {result, _log} = with_log(fn -> Reddit.fetch(context("acme", ~w(nosuchsub)), nil) end)

      # A client whose only subreddit is refused sees why.
      assert {:error, {:http_error, 302}, _state} = result
      assert length(RedditStub.requests()) == 2
    end
  end

  describe "Listings" do
    test "parse/1 drops deleted and removed items", fixtures do
      names = fixtures.comments |> Listings.parse() |> Enum.map(& &1.name)
      assert names == ["t1_c1hit", "t1_c3nom"]

      names = fixtures.new |> Listings.parse() |> Enum.map(& &1.name)
      refute "t3_p4del" in names
    end

    test "add/4 remembers what it has seen, and buffers only the recent", fixtures do
      items = Listings.parse(fixtures.new)

      {listings, 4} = Listings.add(Listings.new(), items, @now_ms, :timer.hours(24))
      {listings, 0} = Listings.add(listings, items, @now_ms, :timer.hours(24))

      assert listings.seq == 3
      refute Enum.any?(listings.buffer, &(&1.name == "t3_p5old"))
    end

    test "begin_poll/4 forgets items past the lookback", fixtures do
      items = Listings.parse(fixtures.new)
      {listings, _new} = Listings.add(Listings.new(), items, @now_ms, :timer.hours(24))

      listings = Listings.begin_poll(listings, 1, @now_ms + :timer.hours(25), :timer.hours(24))

      assert listings.seen == %{}
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp install(fixtures, opts \\ []) do
    if opts[:serve] do
      RedditStub.install(
        token: RedditStub.token(),
        new: serve(fixtures.new),
        comments: serve(fixtures.comments)
      )
    else
      RedditStub.install(
        token: RedditStub.token(),
        new: RedditStub.listing(fixtures.new),
        comments: RedditStub.listing(fixtures.comments)
      )
    end
  end

  # A listing as Reddit would serve it for the subreddits in the URL.
  defp serve(listing) do
    fn url ->
      [_, subs] = Regex.run(~r{/r/([^/]+)/}, URI.parse(url).path)
      subs = subs |> String.split("+") |> Enum.map(&String.downcase/1)

      children =
        Enum.filter(
          listing["data"]["children"],
          &(String.downcase(&1["data"]["subreddit"]) in subs)
        )

      RedditStub.listing(put_in(listing, ["data", "children"], children))
    end
  end

  defp prepend(child, listing), do: update_in(listing, ["data", "children"], &[child | &1])

  defp post(id, subreddit, title, age_s) do
    %{
      "kind" => "t3",
      "data" => %{
        "id" => id,
        "name" => "t3_" <> id,
        "subreddit" => subreddit,
        "author" => "poster_" <> id,
        "title" => title,
        "selftext" => "",
        "permalink" => "/r/#{subreddit}/comments/#{id}/post/",
        "created_utc" => div(@now_ms, 1_000) - age_s
      }
    }
  end

  defp full_page(page) do
    children =
      for n <- 0..99,
          do: post("g#{page}x#{n}", "marketing", "RealOffice #{page}-#{n}", page * 100 + n)

    %{"data" => %{"children" => children, "after" => "t3_g#{page}x99"}}
  end

  defp context(client_id, subreddits, overrides \\ []) do
    {keywords, overrides} = Keyword.pop(overrides, :keywords, ["realoffice", "real office"])

    client = %SmmMonitor.Client{
      id: client_id,
      name: client_id,
      keywords: keywords,
      subreddits: subreddits
    }

    %{
      platform: :reddit,
      client: client,
      keywords: keywords,
      subreddits: subreddits,
      credentials: @credentials,
      opts: [req_options: RedditStub.req_options(), clock: fn -> @now_ms end] ++ overrides,
      poll_count: 0,
      interval_ms: 15_000
    }
  end
end
