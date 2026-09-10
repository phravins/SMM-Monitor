defmodule SmmMonitor.Fetchers.ConfigPickupTest do
  @moduledoc """
  The promise the config screen makes: change a brand term, and the very
  next poll searches for the new one — no restart.

  Covered at two levels. The worker level proves the whole loop with real
  workers and the mock fetchers; the fetcher level proves the live Reddit
  and YouTube requests carry the new term, using their stub transports so
  nothing touches the network.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.{Config, Monitor}
  alias SmmMonitor.Fetchers.{PlatformSupervisor, Reddit, Worker, YouTube}
  alias SmmMonitor.{RedditStub, YouTubeStub}

  setup do
    original = Config.all()
    Monitor.reset()

    on_exit(fn ->
      Config.put_keywords(original.keywords)
      Config.put_subreddits(original.subreddits)
    end)

    :ok
  end

  describe "a running worker" do
    test "searches for the new term on its next poll" do
      Config.put_keywords("originalterm")

      capture_log(fn ->
        start_supervised!(
          {PlatformSupervisor, platform: :reddit, module: Reddit, interval_ms: 60_000},
          id: {:worker, :reddit}
        )

        assert eventually(fn -> polled?(:reddit) end)
      end)

      assert mentions_mentioning("originalterm") > 0

      # The change a user would make from the config screen.
      Config.put_keywords("replacementterm")
      Monitor.reset()

      # A mock poll yields 0-2 mentions, so drive polls until some arrive
      # rather than assuming one is enough.
      assert poll_until(:reddit, fn -> mentions_mentioning("replacementterm") > 0 end)

      # And nothing is still searching for the old one.
      assert mentions_mentioning("originalterm") == 0
    end

    test "picks it up without restarting the worker" do
      Config.put_keywords("beforechange")

      capture_log(fn ->
        start_supervised!(
          {PlatformSupervisor, platform: :youtube, module: YouTube, interval_ms: 60_000},
          id: {:worker, :youtube}
        )

        assert eventually(fn -> polled?(:youtube) end)
      end)

      pid = Process.whereis(Worker.name(:youtube))

      Config.put_keywords("afterchange")
      Monitor.reset()

      assert poll_until(:youtube, fn -> mentions_mentioning("afterchange") > 0 end)
      # Same process throughout: no restart was needed.
      assert Process.whereis(Worker.name(:youtube)) == pid
    end
  end

  describe "the live Reddit request" do
    test "carries the current keywords and subreddits" do
      Config.put_keywords("liveterm")
      Config.put_subreddits("configuredsub")

      RedditStub.install(
        token: RedditStub.token(),
        search: RedditStub.listing(%{"data" => %{"children" => []}})
      )

      Reddit.fetch(reddit_context(), Reddit.State.new())

      assert [{:get, url}] = RedditStub.search_requests()
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["q"] == "liveterm"
      # The subreddit list from the config screen, not the compile-time one.
      assert url =~ "/r/configuredsub/search"
    end

    test "reflects a subreddit list cleared to empty" do
      Config.put_subreddits("")

      RedditStub.install(
        token: RedditStub.token(),
        search: RedditStub.listing(%{"data" => %{"children" => []}})
      )

      Reddit.fetch(reddit_context(), Reddit.State.new())

      assert [{:get, url}] = RedditStub.search_requests()
      # Empty means search all of Reddit.
      assert url =~ "oauth.reddit.com/search"
    end
  end

  describe "the live YouTube request" do
    test "carries the current keywords" do
      Config.put_keywords("ytterm, yt phrase")

      YouTubeStub.install(YouTubeStub.results(%{"items" => []}))

      YouTube.fetch(youtube_context(), YouTube.State.new())

      assert YouTubeStub.query_params()["q"] == ~s(ytterm | "yt phrase")
    end
  end

  describe "Config as the single source of truth" do
    test "both live platforms search for the same brand terms" do
      # The point of one shared setting rather than a per-platform one.
      Config.put_keywords("sharedterm")

      RedditStub.install(
        token: RedditStub.token(),
        search: RedditStub.listing(%{"data" => %{"children" => []}})
      )

      YouTubeStub.install(YouTubeStub.results(%{"items" => []}))

      Reddit.fetch(reddit_context(), Reddit.State.new())
      YouTube.fetch(youtube_context(), YouTube.State.new())

      [{:get, reddit_url}] = RedditStub.search_requests()

      assert reddit_url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("q") ==
               "sharedterm"

      assert YouTubeStub.query_params()["q"] == "sharedterm"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp reddit_context do
    %{
      platform: :reddit,
      keywords: Config.keywords(),
      credentials: [client_id: "id", client_secret: "secret"],
      opts: [req_options: RedditStub.req_options()],
      poll_count: 0,
      interval_ms: 30_000
    }
  end

  defp youtube_context do
    %{
      platform: :youtube,
      keywords: Config.keywords(),
      credentials: [api_key: "key"],
      opts: [req_options: YouTubeStub.req_options()],
      poll_count: 0,
      interval_ms: :timer.minutes(18)
    }
  end

  defp mentions_mentioning(term) do
    :all
    |> Monitor.recent(500)
    |> Enum.count(&String.contains?(&1.text, term))
  end

  defp polled?(platform) do
    match?(%{poll_count: count} when count > 0, Worker.status(platform))
  end

  # Drives polls until the condition holds: a single mock poll can return
  # no mentions at all.
  defp poll_until(platform, check, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if check.() do
        {:halt, true}
      else
        Worker.poll_now(platform)
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
