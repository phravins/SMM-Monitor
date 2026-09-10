defmodule SmmMonitor.Fetchers.Reddit.RateLimitTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Reddit.RateLimit

  @now 1_700_000_000_000

  describe "check/2 before any response has been seen" do
    test "allows a request" do
      assert :ok = RateLimit.check(RateLimit.new(), @now)
    end

    test "backs off once we've made too many requests inside a minute" do
      # Nothing from Reddit to go on yet, so a local count stands in. This is
      # what protects the burst of polls right after startup.
      rate_limit =
        Enum.reduce(1..55, RateLimit.new(), fn index, acc ->
          RateLimit.record_request(acc, @now + index)
        end)

      assert {:backoff, ms} = RateLimit.check(rate_limit, @now + 100)
      assert ms > 0
    end

    test "forgets requests older than the window" do
      rate_limit =
        Enum.reduce(1..55, RateLimit.new(), fn index, acc ->
          RateLimit.record_request(acc, @now + index)
        end)

      # A minute later those requests no longer count against us.
      assert :ok = RateLimit.check(rate_limit, @now + :timer.minutes(2))
    end
  end

  describe "check/2 with observed headers" do
    test "allows a request with plenty of quota left" do
      rate_limit = observe(RateLimit.new(), "58.0", "2.0", "55")

      assert :ok = RateLimit.check(rate_limit, @now)
    end

    test "backs off before the quota reaches zero" do
      # Five requests are held in reserve, so a burst from something else
      # sharing these credentials can't push us into a hard 429.
      rate_limit = observe(RateLimit.new(), "3.0", "57.0", "20")

      assert {:backoff, ms} = RateLimit.check(rate_limit, @now)
      assert ms == 20_000
    end

    test "backs off for at least a second, even at the reset boundary" do
      rate_limit = observe(RateLimit.new(), "0.0", "60.0", "0.2")

      assert {:backoff, 1_000} = RateLimit.check(rate_limit, @now)
    end

    test "allows requests again once the window has reset" do
      rate_limit = observe(RateLimit.new(), "1.0", "59.0", "10")

      assert :ok = RateLimit.check(rate_limit, @now + :timer.seconds(11))
    end
  end

  describe "observe/3" do
    test "reads Reddit's headers" do
      rate_limit = observe(RateLimit.new(), "58.0", "2.0", "55")

      assert rate_limit.remaining == 58.0
      assert rate_limit.used == 2.0
      assert rate_limit.reset_at == @now + 55_000
      assert rate_limit.observed_at == @now
    end

    test "is case insensitive and accepts plain string values" do
      headers = %{"X-Ratelimit-Remaining" => "42.0", "X-RateLimit-Reset" => "30"}
      rate_limit = RateLimit.observe(RateLimit.new(), headers, @now)

      assert rate_limit.remaining == 42.0
    end

    test "keeps the previous reading when headers are absent" do
      # A response without headers is not evidence of a fresh quota.
      rate_limit = RateLimit.new() |> observe("3.0", "57.0", "20") |> RateLimit.observe(%{}, @now)

      assert rate_limit.remaining == 3.0
      assert {:backoff, _ms} = RateLimit.check(rate_limit, @now)
    end

    test "ignores unparseable header values" do
      rate_limit =
        RateLimit.new()
        |> observe("10.0", "50.0", "30")
        |> RateLimit.observe(%{"x-ratelimit-remaining" => ["nonsense"]}, @now)

      assert rate_limit.remaining == 10.0
    end
  end

  describe "summary/1" do
    test "is nil until we've seen a response" do
      assert RateLimit.summary(RateLimit.new()) == nil
    end

    test "reports the remaining quota" do
      assert RateLimit.summary(observe(RateLimit.new(), "58.0", "2.0", "55")) =~ "58 requests left"
    end
  end

  defp observe(rate_limit, remaining, used, reset_in_s) do
    RateLimit.observe(
      rate_limit,
      SmmMonitor.RedditStub.rate_limit_headers(remaining, used, reset_in_s),
      @now
    )
  end
end
