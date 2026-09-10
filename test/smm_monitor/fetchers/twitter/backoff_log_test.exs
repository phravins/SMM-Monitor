defmodule SmmMonitor.Fetchers.Twitter.BackoffLogTest do
  @moduledoc """
  What the operator actually sees when Twitter stands itself down.

  Backing off *before* a limit is routine, so it logs at `:info` — below
  the suite's level. This file raises the level to check the message is
  worth reading, which is why it is the one Twitter test that isn't async.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias SmmMonitor.Fetchers.Twitter
  alias SmmMonitor.Fetchers.Twitter.{PostBudget, RateLimit, State}
  alias SmmMonitor.TwitterStub

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "proactive backoff says why, and for how long" do
    state = %{
      State.new()
      | rate_limit:
          RateLimit.observe(
            RateLimit.new(),
            TwitterStub.rate_limit_headers(1, 300),
            System.system_time(:millisecond)
          )
    }

    TwitterStub.install(TwitterStub.no_results())

    log = capture_log(fn -> Twitter.fetch(context(), state) end)

    assert log =~ "twitter"
    assert log =~ "backing off"
    # The window it is waiting on, and what it knows about it.
    assert log =~ "15-minute request limit"
    assert log =~ "requests left this window"
  end

  test "a spent post budget names the limit and the way out" do
    state = %{State.new(30) | post_budget: PostBudget.spend(PostBudget.new(30), 25)}
    TwitterStub.install(TwitterStub.no_results())

    log = capture_log(fn -> Twitter.fetch(context(monthly_post_budget: 30), state) end)

    assert log =~ "monthly post budget spent"
    assert log =~ "25/30 posts used"
    assert log =~ "SMM_TWITTER_MONTHLY_POST_BUDGET"
  end

  defp context(overrides \\ []) do
    %{
      platform: :twitter,
      keywords: ["realoffice"],
      credentials: [bearer_token: "AAAA-test"],
      opts: [req_options: TwitterStub.req_options()] ++ overrides,
      poll_count: 0,
      interval_ms: :timer.minutes(5)
    }
  end
end
