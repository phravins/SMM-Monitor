defmodule SmmMonitor.Fetchers.Twitter.FetchTest do
  @moduledoc """
  The whole live fetch path — token handling, request building, parsing,
  and both kinds of limit — against a stub transport. No network, no
  token, no posts spent from anyone's cap.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias SmmMonitor.Fetchers.Twitter
  alias SmmMonitor.Fetchers.Twitter.{PostBudget, RateLimit, State}
  alias SmmMonitor.TwitterStub

  @credentials [bearer_token: "AAAAtest-bearer-token"]

  setup_all do
    {:ok, body: "test/fixtures/twitter_search_recent.json" |> File.read!() |> Jason.decode!()}
  end

  describe "fetch/2 happy path" do
    test "searches and returns parsed mentions", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      assert {:ok, mentions, _state} = Twitter.fetch(context(), State.new())

      assert length(mentions) == 3
      assert Enum.all?(mentions, &(&1.platform == :twitter))
    end

    test "authenticates with the bearer token, app-only", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      Twitter.fetch(context(), State.new())

      assert TwitterStub.request_headers()["authorization"] ==
               "Bearer AAAAtest-bearer-token"
    end

    test "searches for the shared brand keywords", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      Twitter.fetch(context(), State.new())

      # The same :keywords every other platform uses, not a Twitter-only list.
      assert TwitterStub.query_params()["query"] ==
               ~s|(realoffice OR "real office") -is:retweet|
    end

    test "asks for the fields the mention struct needs", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      Twitter.fetch(context(), State.new())
      params = TwitterStub.query_params()

      # Without the expansion, tweets carry an author_id and no handle.
      assert params["expansions"] == "author_id"
      assert params["tweet.fields"] =~ "created_at"
      assert params["tweet.fields"] =~ "author_id"
      assert params["user.fields"] =~ "username"
    end

    test "makes exactly one request per poll", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      Twitter.fetch(context(), State.new())

      assert length(TwitterStub.requests()) == 1
    end

    test "keeps the page size inside the API's 10..100 bounds", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      Twitter.fetch(context(max_results: 5_000), State.new())
      assert TwitterStub.query_params()["max_results"] == "100"

      TwitterStub.install(TwitterStub.results(body))
      Twitter.fetch(context(max_results: 1), State.new())
      assert TwitterStub.query_params()["max_results"] == "10"
    end

    test "a search that matched nothing is a success, not an error" do
      TwitterStub.install(TwitterStub.no_results())

      assert {:ok, [], _state} = Twitter.fetch(context(), State.new())
    end
  end

  describe "the monthly post cap" do
    test "counts the posts a search actually returned", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      {:ok, _mentions, state} = Twitter.fetch(context(), State.new())

      # Three tweets came back, so three posts were consumed — not the 25
      # the page asked for.
      assert state.post_budget.used == 3
      assert state.post_budget.calls == 1
    end

    test "accumulates across polls", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))

      state =
        Enum.reduce(1..4, State.new(), fn _i, acc ->
          {:ok, _mentions, next} = Twitter.fetch(context(), acc)
          next
        end)

      assert state.post_budget.used == 12
      assert state.post_budget.calls == 4
    end

    test "an empty result set spends nothing" do
      TwitterStub.install(TwitterStub.no_results())

      {:ok, [], state} = Twitter.fetch(context(), State.new())

      assert state.post_budget.used == 0
    end

    test "stands down before overrunning the budget, without calling the API" do
      TwitterStub.install(TwitterStub.no_results())
      state = spend_budget(State.new(30), 25)

      {result, log} = with_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

      assert {:error, {:quota_exhausted, wait_ms}, _state} = result
      assert wait_ms > 0
      # The point of a budget: the request is never made.
      assert TwitterStub.requests() == []
      assert log =~ "monthly post budget spent"
    end

    test "says how to raise the budget when it stands down" do
      TwitterStub.install(TwitterStub.no_results())
      state = spend_budget(State.new(30), 25)

      log = capture_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

      assert log =~ "SMM_TWITTER_MONTHLY_POST_BUDGET"
    end

    test "reports standing down once, not on every poll" do
      TwitterStub.install(TwitterStub.no_results())
      state = spend_budget(State.new(30), 25)

      {_result, first} = with_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

      {{:error, _reason, state}, _log} =
        with_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

      {_result, second} = with_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

      assert first =~ "monthly post budget spent"
      refute second =~ "monthly post budget spent"
    end

    test "trims the page rather than standing down with budget left", %{body: body} do
      TwitterStub.install(TwitterStub.results(body))
      state = spend_budget(State.new(100), 88)

      Twitter.fetch(context(monthly_post_budget: 100), state)

      # 12 posts left, so ask for 12 rather than the configured 25.
      assert TwitterStub.query_params()["max_results"] == "12"
    end
  end

  describe "the 15-minute request window" do
    test "records what X reports about the window", %{body: body} do
      TwitterStub.install(TwitterStub.results(body, TwitterStub.rate_limit_headers(300)))

      {:ok, _mentions, state} = Twitter.fetch(context(), State.new())

      assert state.rate_limit.remaining == 300.0
      assert RateLimit.summary(state.rate_limit) == "300/450 requests left this window"
    end

    test "backs off before the window runs out, without calling the API", %{body: body} do
      TwitterStub.install(TwitterStub.results(body, TwitterStub.rate_limit_headers(1)))
      {:ok, _mentions, state} = Twitter.fetch(context(), State.new())

      TwitterStub.install(TwitterStub.results(body))
      result = Twitter.fetch(context(), state)

      assert {:error, {:rate_limited, wait_ms}, _state} = result
      assert wait_ms > 0
      # The point of tracking the window: the request is never made.
      assert TwitterStub.requests() == []
    end

    test "a 429 waits for the window X named, not a fixed guess" do
      TwitterStub.install(TwitterStub.rate_limited(240))

      {result, log} = with_log(fn -> Twitter.fetch(context(), State.new()) end)

      assert {:error, {:rate_limited, wait_ms}, _state} = result
      assert_in_delta wait_ms, :timer.seconds(240), :timer.seconds(5)
      assert log =~ "rate limited by X"
    end

    test "the worker is told to retry, so a limit is never fatal" do
      TwitterStub.install(TwitterStub.rate_limited(120))

      {:error, reason, _state} = capture(fn -> Twitter.fetch(context(), State.new()) end)

      assert SmmMonitor.Fetchers.Fetcher.retry_after(reason) > 0
    end
  end

  describe "a 429 for the monthly cap" do
    test "is told apart from a window limit by its body" do
      # The two share a status code and ask for wildly different waits:
      # fifteen minutes versus the rest of the billing cycle.
      TwitterStub.install(TwitterStub.usage_capped())

      {result, log} = with_log(fn -> Twitter.fetch(context(), State.new()) end)

      assert {:error, {:quota_exhausted, wait_ms}, _state} = result
      assert wait_ms > :timer.hours(1)
      assert log =~ "monthly post cap is spent"
    end

    test "believes X over our own count, and stops polling until reset" do
      TwitterStub.install(TwitterStub.usage_capped())

      {:error, _reason, state} = capture(fn -> Twitter.fetch(context(), State.new()) end)

      # Our count said the budget was untouched; X says otherwise.
      assert PostBudget.remaining(state.post_budget) == 0

      TwitterStub.install(TwitterStub.no_results())

      assert {:error, {:quota_exhausted, _ms}, _state} =
               capture(fn -> Twitter.fetch(context(), state) end)

      assert TwitterStub.requests() == []
    end
  end

  describe "credential and access errors" do
    test "a rejected token is reported as such" do
      TwitterStub.install(TwitterStub.unauthorized())

      assert {:error, :invalid_bearer_token, _state} = Twitter.fetch(context(), State.new())
    end

    test "a tier without search access is reported separately from a bad token" do
      # A free-tier token is valid but can't search; these need different fixes.
      TwitterStub.install(TwitterStub.forbidden())

      assert {:error, {:forbidden, detail}, _state} = Twitter.fetch(context(), State.new())
      assert detail =~ "Project"
    end

    test "an unexpected status is surfaced with its code" do
      TwitterStub.install(Req.Response.new(status: 503, body: ""))

      assert {:error, {:http_error, 503}, _state} = Twitter.fetch(context(), State.new())
    end

    test "a transport failure is surfaced rather than raised" do
      TwitterStub.install(%Req.TransportError{reason: :timeout})

      assert {:error, {:transport, _reason}, _state} = Twitter.fetch(context(), State.new())
    end

    test "an error leaves the state usable for the next poll", %{body: body} do
      TwitterStub.install([TwitterStub.unauthorized(), TwitterStub.results(body)])

      {:error, _reason, state} = Twitter.fetch(context(), State.new())

      assert {:ok, mentions, _state} = Twitter.fetch(context(), state)
      assert length(mentions) == 3
    end
  end

  describe "ready?/1" do
    test "is what decides live vs. fallback" do
      refute Twitter.ready?(context(credentials: []))
      refute Twitter.ready?(context(credentials: [bearer_token: nil]))
      refute Twitter.ready?(context(credentials: [bearer_token: "   "]))
      assert Twitter.ready?(context(credentials: [bearer_token: "AAAA"]))
    end
  end

  describe "init_state/1" do
    test "takes the budget and cycle day from config" do
      state = Twitter.init_state(context(monthly_post_budget: 50_000, billing_cycle_day: 12))

      assert state.post_budget.budget == 50_000
      assert state.post_budget.cycle_day == 12
    end

    test "defaults conservatively when nothing is configured" do
      state = Twitter.init_state(context())

      assert state.post_budget.budget == 10_000
      assert state.post_budget.cycle_day == 1
    end
  end

  # --- helpers --------------------------------------------------------------

  defp context(overrides \\ []) do
    {credentials, overrides} = Keyword.pop(overrides, :credentials, @credentials)

    %{
      platform: :twitter,
      keywords: ["realoffice", "real office"],
      credentials: credentials,
      opts: [req_options: TwitterStub.req_options()] ++ overrides,
      poll_count: 0,
      interval_ms: :timer.minutes(5)
    }
  end

  defp spend_budget(state, posts) do
    %{state | post_budget: PostBudget.spend(state.post_budget, posts)}
  end

  defp capture(fun) do
    {result, _log} = with_log(fun)
    result
  end
end
