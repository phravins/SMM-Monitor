defmodule SmmMonitor.Fetchers.Reddit.FetchTest do
  @moduledoc """
  Exercises the whole live fetch path — auth, request building, parsing,
  rate limiting — against a stub transport. No network, no credentials.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Reddit
  alias SmmMonitor.Fetchers.Reddit.{Auth, State}
  alias SmmMonitor.RedditStub

  @credentials [client_id: "id", client_secret: "secret", user_agent: "smm_monitor/test"]

  setup_all do
    {:ok, listing: "test/fixtures/reddit_search.json" |> File.read!() |> Jason.decode!()}
  end

  describe "fetch/2 happy path" do
    test "authenticates, searches and returns parsed mentions", %{listing: listing} do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      assert {:ok, mentions, state} = Reddit.fetch(context(), State.new())

      assert length(mentions) == 5
      assert Enum.all?(mentions, &(&1.platform == :reddit))
      assert state.auth.token == "stub-token"
    end

    test "makes exactly one search request per poll", %{listing: listing} do
      # Subreddits are combined into one multireddit search rather than one
      # request each, which is what keeps polling clear of the rate limit.
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      Reddit.fetch(context(subreddits: ["marketing", "smallbusiness", "socialmedia"]), State.new())

      assert [{:get, url}] = RedditStub.search_requests()
      assert url =~ "/r/marketing+smallbusiness+socialmedia/search"
    end

    test "sends the query, sort, limit and restrict_sr", %{listing: listing} do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      Reddit.fetch(context(), State.new())

      assert [{:get, url}] = RedditStub.search_requests()
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["q"] == ~s(realoffice OR "real office")
      assert query["sort"] == "new"
      assert query["limit"] == "25"
      assert query["restrict_sr"] == "true"
      assert query["raw_json"] == "1"
    end

    test "searches site-wide without restrict_sr when no subreddits are set", %{listing: listing} do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      Reddit.fetch(context(subreddits: []), State.new())

      assert [{:get, url}] = RedditStub.search_requests()
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert url =~ "oauth.reddit.com/search"
      assert query["restrict_sr"] == "false"
    end

    test "caps the limit at Reddit's maximum of 100", %{listing: listing} do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      Reddit.fetch(context(limit: 5_000), State.new())

      assert [{:get, url}] = RedditStub.search_requests()

      assert url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("limit") ==
               "100"
    end

    test "reuses the cached token across polls", %{listing: listing} do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.listing(listing))

      {:ok, _mentions, state} = Reddit.fetch(context(), State.new())
      {:ok, _mentions, state} = Reddit.fetch(context(), state)
      {:ok, _mentions, _state} = Reddit.fetch(context(), state)

      assert length(RedditStub.token_requests()) == 1
      assert length(RedditStub.search_requests()) == 3
    end

    test "records the rate-limit quota from the response", %{listing: listing} do
      RedditStub.install(
        token: RedditStub.token(),
        search: RedditStub.listing(listing, RedditStub.rate_limit_headers("41.0", "19.0", "40"))
      )

      {:ok, _mentions, state} = Reddit.fetch(context(), State.new())

      assert state.rate_limit.remaining == 41.0
    end
  end

  describe "fetch/2 failures" do
    test "surfaces missing credentials without calling out" do
      RedditStub.install([])

      assert {:error, :missing_credentials, _state} =
               Reddit.fetch(context(credentials: []), State.new())

      assert RedditStub.requests() == []
    end

    test "drops a rejected token so the next poll re-authenticates", %{listing: listing} do
      RedditStub.install(
        token: RedditStub.token(),
        search: [RedditStub.error(401), RedditStub.listing(listing)]
      )

      assert {:error, :unauthorized, state} = Reddit.fetch(context(), State.new())
      # The cached token is gone, so the retry starts by getting a new one.
      refute Auth.valid?(state.auth)

      assert {:ok, mentions, _state} = Reddit.fetch(context(), state)
      assert length(mentions) == 5
      assert length(RedditStub.token_requests()) == 2
    end

    test "turns a 429 into a backoff the worker can act on" do
      RedditStub.install(
        token: RedditStub.token(),
        search: RedditStub.error(429, RedditStub.rate_limit_headers("0.0", "60.0", "30"))
      )

      assert {:error, {:rate_limited, wait_ms}, _state} = Reddit.fetch(context(), State.new())
      assert wait_ms > 0
      # The worker reads this to postpone the next poll.
      assert SmmMonitor.Fetchers.Fetcher.retry_after({:rate_limited, wait_ms}) == wait_ms
    end

    test "backs off without spending a request when quota is nearly gone" do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.error(429))

      exhausted = %State{
        auth: Auth.new(),
        rate_limit:
          SmmMonitor.Fetchers.Reddit.RateLimit.observe(
            SmmMonitor.Fetchers.Reddit.RateLimit.new(),
            RedditStub.rate_limit_headers("1.0", "59.0", "30")
          )
      }

      assert {:error, {:rate_limited, _ms}, _state} = Reddit.fetch(context(), exhausted)
      # The point: we didn't even try.
      assert RedditStub.requests() == []
    end

    test "reports other HTTP errors with the status" do
      RedditStub.install(token: RedditStub.token(), search: RedditStub.error(503))

      assert {:error, {:http_error, 503}, _state} = Reddit.fetch(context(), State.new())
    end

    test "tolerates being handed nil state" do
      # The worker builds state via init_state/1, but a fetcher shouldn't
      # explode if it is ever called cold.
      RedditStub.install([])

      assert {:error, :missing_credentials, %State{}} = Reddit.fetch(context(credentials: []), nil)
    end
  end

  describe "ready?/1" do
    test "requires both halves of the credential pair" do
      refute Reddit.ready?(context(credentials: []))
      refute Reddit.ready?(context(credentials: [client_id: "id"]))
      refute Reddit.ready?(context(credentials: [client_secret: "secret"]))
      assert Reddit.ready?(context(credentials: @credentials))
    end

    test "treats blank credentials as missing" do
      refute Reddit.ready?(context(credentials: [client_id: "  ", client_secret: "secret"]))
    end
  end

  describe "init_state/1" do
    test "starts with no token and no observed quota" do
      state = Reddit.init_state(context())

      assert %State{} = state
      refute Auth.valid?(state.auth)
      assert state.rate_limit.remaining == nil
    end
  end

  defp context(overrides \\ []) do
    {credentials, overrides} = Keyword.pop(overrides, :credentials, @credentials)

    opts =
      [subreddits: ["marketing"], limit: 25, sort: "new", time_filter: "week"]
      |> Keyword.merge(overrides)
      |> Keyword.merge(RedditStub.req_options() |> then(&[req_options: &1]))

    %{
      platform: :reddit,
      keywords: ["realoffice", "real office"],
      credentials: credentials,
      opts: opts,
      poll_count: 0
    }
  end
end
