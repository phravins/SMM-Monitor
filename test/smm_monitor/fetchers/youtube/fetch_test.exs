defmodule SmmMonitor.Fetchers.YouTube.FetchTest do
  @moduledoc """
  The whole live fetch path — key handling, request building, parsing,
  quota accounting — against a stub transport. No network, no key, no
  quota spent.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias SmmMonitor.Fetchers.YouTube
  alias SmmMonitor.Fetchers.YouTube.{Quota, State}
  alias SmmMonitor.YouTubeStub

  @credentials [api_key: "test-key"]

  setup_all do
    {:ok, body: "test/fixtures/youtube_search.json" |> File.read!() |> Jason.decode!()}
  end

  describe "fetch/2 happy path" do
    test "searches and returns parsed mentions", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      assert {:ok, mentions, _state} = YouTube.fetch(context(), State.new())

      assert length(mentions) == 3
      assert Enum.all?(mentions, &(&1.platform == :youtube))
    end

    test "sends the API key and the shared brand keywords", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      YouTube.fetch(context(), State.new())
      params = YouTubeStub.query_params()

      assert params["key"] == "test-key"
      # The same :keywords every other platform searches for, not a
      # YouTube-specific setting.
      assert params["q"] == ~s(realoffice | "real office")
      assert params["type"] == "video"
      assert params["part"] == "snippet"
      assert params["order"] == "date"
    end

    test "bounds the search to recently published videos", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      YouTube.fetch(context(published_within_ms: :timer.hours(24)), State.new())

      published_after = YouTubeStub.query_params()["publishedAfter"]
      assert {:ok, timestamp, _offset} = DateTime.from_iso8601(published_after)

      hours_ago = DateTime.diff(DateTime.utc_now(), timestamp, :second) / 3_600
      assert_in_delta hours_ago, 24, 1
    end

    test "caps maxResults at the API's page limit of 50", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      YouTube.fetch(context(max_results: 500), State.new())

      assert YouTubeStub.query_params()["maxResults"] == "50"
    end

    test "makes exactly one search per poll", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      YouTube.fetch(context(), State.new())

      assert length(YouTubeStub.requests()) == 1
    end
  end

  describe "quota accounting" do
    test "spends 100 units per search", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      {:ok, _mentions, state} = YouTube.fetch(context(), State.new())

      assert state.quota.used == 100
      assert state.quota.calls == 1
    end

    test "accumulates across polls", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      state =
        Enum.reduce(1..3, State.new(), fn _i, acc ->
          {:ok, _mentions, next} = YouTube.fetch(context(), acc)
          next
        end)

      assert state.quota.used == 300
    end

    test "spends the units even when the call fails" do
      # A request that reaches Google counts against the quota whether or
      # not we like the response.
      YouTubeStub.install(YouTubeStub.error(500, "backendError"))

      assert {:error, _reason, state} = YouTube.fetch(context(), State.new())
      assert state.quota.used == 100
    end

    test "stops polling once the budget is spent, without calling out", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      # A budget of 200 units buys exactly two searches.
      state = State.new(200)
      {:ok, _mentions, state} = YouTube.fetch(context(), state)
      {:ok, _mentions, state} = YouTube.fetch(context(), state)

      log =
        capture_log(fn ->
          assert {:error, {:quota_exhausted, wait_ms}, _state} = YouTube.fetch(context(), state)
          assert wait_ms > 0
        end)

      # Two calls made, and the third never left the process.
      assert length(YouTubeStub.requests()) == 2
      assert log =~ "daily quota budget spent"
      assert log =~ "midnight Pacific"
    end

    test "reports the cutoff once, not on every poll while standing down", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      state = State.new(100)
      {:ok, _mentions, state} = YouTube.fetch(context(), state)

      # Thread the state through: it's the flag on the *returned* state
      # that suppresses the repeat.
      {{:error, _reason, state}, first} = with_log(fn -> YouTube.fetch(context(), state) end)
      {{:error, _reason, _state}, second} = with_log(fn -> YouTube.fetch(context(), state) end)

      assert first =~ "daily quota budget spent"
      refute second =~ "daily quota budget spent"
    end

    test "the worker treats the cutoff as a backoff instruction" do
      YouTubeStub.install(YouTubeStub.error(403, "quotaExceeded"))

      capture_log(fn ->
        {:error, reason, _state} = YouTube.fetch(context(), State.new())
        assert SmmMonitor.Fetchers.Fetcher.retry_after(reason) > 0
      end)
    end
  end

  describe "fetch/2 failures" do
    test "believes Google over our own count when it says the quota is gone" do
      # Something else sharing the key can spend quota we never saw, so a
      # quotaExceeded means stand down regardless of our own estimate.
      YouTubeStub.install(YouTubeStub.error(403, "quotaExceeded"))

      log =
        capture_log(fn ->
          assert {:error, {:quota_exhausted, wait_ms}, state} =
                   YouTube.fetch(context(), State.new())

          assert wait_ms > 0
          # Local budget is written off, so we don't immediately retry.
          assert {:exhausted, _ms} = Quota.check(state.quota, 100, DateTime.utc_now())
        end)

      assert log =~ "Google reports the API quota is spent"
    end

    test "treats dailyLimitExceeded the same way" do
      YouTubeStub.install(YouTubeStub.error(403, "dailyLimitExceeded"))

      capture_log(fn ->
        assert {:error, {:quota_exhausted, _ms}, _state} = YouTube.fetch(context(), State.new())
      end)
    end

    test "distinguishes a bad key from a spent quota" do
      # Both come back as 403, but one resolves itself overnight and the
      # other needs the key fixing — so they must not look the same.
      YouTubeStub.install(YouTubeStub.error(403, "keyInvalid"))

      assert {:error, {:forbidden, "keyInvalid"}, _state} = YouTube.fetch(context(), State.new())
    end

    test "reports a malformed request with Google's reason and message" do
      YouTubeStub.install(YouTubeStub.error(400, "invalidSearchFilter"))

      assert {:error, {:bad_request, "invalidSearchFilter", message}, _state} =
               YouTube.fetch(context(), State.new())

      assert message =~ "invalidSearchFilter"
    end

    test "calls out an invalid API key specifically" do
      # This is the real 400 you get from Google with a bad key. Its
      # machine reason is just "badRequest" — the useful part is in the
      # message and the details, so the error has to carry it or the log
      # tells you nothing actionable.
      YouTubeStub.install(YouTubeStub.invalid_key_error())

      assert {:error, {:invalid_api_key, message}, _state} =
               YouTube.fetch(context(), State.new())

      assert message =~ "API key not valid"
    end

    test "reports other HTTP errors with the status" do
      YouTubeStub.install(YouTubeStub.error(503, "backendError"))

      assert {:error, {:http_error, 503}, _state} = YouTube.fetch(context(), State.new())
    end

    test "tolerates being handed nil state", %{body: body} do
      YouTubeStub.install(YouTubeStub.results(body))

      assert {:ok, _mentions, %State{}} = YouTube.fetch(context(), nil)
    end
  end

  describe "ready?/1" do
    test "requires an API key" do
      refute YouTube.ready?(context(credentials: []))
      refute YouTube.ready?(context(credentials: [api_key: nil]))
      assert YouTube.ready?(context(credentials: @credentials))
    end

    test "treats a blank key as missing" do
      refute YouTube.ready?(context(credentials: [api_key: "   "]))
    end
  end

  describe "init_state/1" do
    test "starts with an unspent budget from config" do
      state = YouTube.init_state(context(daily_quota_budget: 5_000))

      assert state.quota.budget == 5_000
      assert state.quota.used == 0
    end
  end

  defp context(overrides \\ []) do
    {credentials, overrides} = Keyword.pop(overrides, :credentials, @credentials)

    %{
      platform: :youtube,
      keywords: ["realoffice", "real office"],
      credentials: credentials,
      opts: Keyword.merge([req_options: YouTubeStub.req_options()], overrides),
      poll_count: 0,
      interval_ms: :timer.minutes(18)
    }
  end
end
