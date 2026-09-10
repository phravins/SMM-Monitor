defmodule SmmMonitor.Fetchers.Twitter.RateLimitTest do
  @moduledoc """
  The 15-minute request window: reading X's headers and deciding when to
  hold off. Pure functions with an injected clock — no sleeping.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Twitter.RateLimit

  # A fixed "now" so every expectation is exact.
  @now 1_800_000_000_000

  describe "check/2 before any response has been seen" do
    test "allows the first request" do
      assert RateLimit.check(RateLimit.new(), @now) == :ok
    end

    test "falls back to a local count until headers arrive" do
      # Nothing has told us the real limit yet, so a burst is throttled on
      # our own conservative ceiling rather than on optimism.
      rate_limit =
        Enum.reduce(1..45, RateLimit.new(), fn _i, acc ->
          RateLimit.record_request(acc, @now)
        end)

      assert {:backoff, _ms} = RateLimit.check(rate_limit, @now)
    end

    test "the local count only spans the current window" do
      old_window = @now - :timer.minutes(16)

      rate_limit =
        Enum.reduce(1..45, RateLimit.new(), fn _i, acc ->
          RateLimit.record_request(acc, old_window)
        end)

      # Those requests are in a window that has since reset.
      assert RateLimit.check(rate_limit, @now) == :ok
    end
  end

  describe "observe/3" do
    test "reads limit, remaining and reset from X's headers" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 300, reset_in: 600), @now)

      assert rate_limit.limit == 450.0
      assert rate_limit.remaining == 300.0
      assert rate_limit.observed_at == @now
    end

    test "treats x-rate-limit-reset as an absolute epoch, not a duration" do
      # X sends the wall-clock time the window resets; Reddit sends
      # seconds until. Reading X's value as a duration would schedule the
      # next poll about thirty years out.
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 0, reset_in: 600), @now)

      assert_in_delta RateLimit.ms_until_reset(rate_limit, @now), :timer.minutes(10), 1_000
    end

    test "accepts Req's list-valued headers as well as a plain map" do
      headers = %{
        "x-rate-limit-limit" => ["450"],
        "x-rate-limit-remaining" => ["12"],
        "x-rate-limit-reset" => [to_string(div(@now, 1_000) + 60)]
      }

      assert %{remaining: 12.0} = RateLimit.observe(RateLimit.new(), headers, @now)
    end

    test "is case insensitive about header names" do
      headers = %{"X-Rate-Limit-Remaining" => "7"}

      assert %{remaining: 7.0} = RateLimit.observe(RateLimit.new(), headers, @now)
    end

    test "keeps the previous reading when headers are absent" do
      # A response without the headers must not look like a fresh window.
      seen = RateLimit.observe(RateLimit.new(), headers(450, 3, reset_in: 600), @now)
      after_blank = RateLimit.observe(seen, %{}, @now)

      assert after_blank.remaining == 3.0
      assert after_blank.reset_at == seen.reset_at
    end

    test "keeps the previous reading when headers are unparseable" do
      seen = RateLimit.observe(RateLimit.new(), headers(450, 3, reset_in: 600), @now)
      garbled = RateLimit.observe(seen, %{"x-rate-limit-remaining" => "soon"}, @now)

      assert garbled.remaining == 3.0
    end
  end

  describe "check/2 once X has reported the window" do
    test "allows requests while there is headroom" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 400, reset_in: 600), @now)

      assert RateLimit.check(rate_limit, @now) == :ok
    end

    test "backs off before zero, holding a reserve" do
      # Something else may share these credentials; a hard 429 costs more
      # than a skipped poll.
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 3, reset_in: 600), @now)

      assert {:backoff, wait_ms} = RateLimit.check(rate_limit, @now)
      assert_in_delta wait_ms, :timer.minutes(10), 1_000
    end

    test "waits exactly until the window resets, not a fixed guess" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 0, reset_in: 42), @now)

      assert {:backoff, wait_ms} = RateLimit.check(rate_limit, @now)
      assert_in_delta wait_ms, 42_000, 1_000
    end

    test "resumes once the reset time has passed" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 0, reset_in: 60), @now)

      assert {:backoff, _ms} = RateLimit.check(rate_limit, @now)
      assert RateLimit.check(rate_limit, @now + :timer.minutes(2)) == :ok
    end

    test "never returns a backoff of zero or less" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 0, reset_in: 1), @now)

      assert {:backoff, wait_ms} = RateLimit.check(rate_limit, @now)
      assert wait_ms > 0
    end
  end

  describe "summary/1" do
    test "is nil before anything has been observed" do
      assert RateLimit.summary(RateLimit.new()) == nil
    end

    test "reports what is left of the window" do
      rate_limit = RateLimit.observe(RateLimit.new(), headers(450, 128, reset_in: 600), @now)

      assert RateLimit.summary(rate_limit) == "128/450 requests left this window"
    end
  end

  defp headers(limit, remaining, reset_in: reset_in_s) do
    %{
      "x-rate-limit-limit" => to_string(limit),
      "x-rate-limit-remaining" => to_string(remaining),
      "x-rate-limit-reset" => to_string(div(@now, 1_000) + reset_in_s)
    }
  end
end
