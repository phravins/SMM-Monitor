defmodule SmmMonitor.Fetchers.Instagram.ThrottleTest do
  @moduledoc """
  Meta reports rate limiting as percentages of an opaque allowance rather
  than as a count of requests left, so this is mostly about reading two
  header shapes correctly and reacting before 100.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Instagram.Throttle

  @now 1_800_000_000_000

  describe "check/2" do
    test "allows requests before anything has been observed" do
      assert Throttle.check(Throttle.new(), @now) == :ok
    end

    test "allows requests while usage is comfortable" do
      throttle = Throttle.observe(Throttle.new(), business_usage(40), @now)

      assert Throttle.check(throttle, @now) == :ok
    end

    test "backs off before Meta cuts us off" do
      # The percentage arrives *after* the call that caused it, so waiting
      # for 100 means reacting a request too late.
      throttle = Throttle.observe(Throttle.new(), business_usage(92), @now)

      assert {:backoff, wait_ms} = Throttle.check(throttle, @now)
      assert wait_ms > 0
    end

    test "waits out an explicit block for as long as Meta asked" do
      throttle = Throttle.block(Throttle.new(), 20, @now)

      assert {:backoff, wait_ms} = Throttle.check(throttle, @now)
      assert_in_delta wait_ms, :timer.minutes(20), 1_000
    end

    test "resumes once the block has passed" do
      throttle = Throttle.block(Throttle.new(), 20, @now)

      assert Throttle.check(throttle, @now + :timer.minutes(21)) == :ok
    end

    test "falls back to a sane wait when Meta doesn't say how long" do
      throttle = Throttle.block(Throttle.new(), nil, @now)

      assert {:backoff, wait_ms} = Throttle.check(throttle, @now)
      assert wait_ms > 0
    end
  end

  describe "observe/3" do
    test "reads the per-business usage header" do
      throttle = Throttle.observe(Throttle.new(), business_usage(37), @now)

      assert throttle.usage == 37
      assert throttle.observed_at == @now
    end

    test "reads the app-wide header when the business one is absent" do
      headers = %{"x-app-usage" => ~s({"call_count":61,"total_cputime":3,"total_time":8})}

      assert %{usage: 61} = Throttle.observe(Throttle.new(), headers, @now)
    end

    test "takes the worst of the three metrics" do
      # Exhausting the CPU-time allowance throttles just as hard as
      # exhausting the call count.
      headers = %{"x-app-usage" => ~s({"call_count":10,"total_cputime":97,"total_time":12})}

      assert %{usage: 97} = Throttle.observe(Throttle.new(), headers, @now)
    end

    test "picks up the wait time Meta includes once throttled" do
      throttle = Throttle.observe(Throttle.new(), business_usage(100, 15), @now)

      assert {:backoff, wait_ms} = Throttle.check(throttle, @now)
      assert_in_delta wait_ms, :timer.minutes(15), 1_000
    end

    test "ignores headers that aren't there" do
      assert Throttle.observe(Throttle.new(), %{}, @now) == Throttle.new()
    end

    test "ignores headers that aren't JSON" do
      # A malformed header must not read as a fresh allowance.
      seen = Throttle.observe(Throttle.new(), business_usage(80), @now)
      after_garbage = Throttle.observe(seen, %{"x-app-usage" => "not json"}, @now)

      assert after_garbage.usage == 80
    end

    test "accepts Req's list-valued headers" do
      headers = %{"x-app-usage" => [~s({"call_count":25})]}

      assert %{usage: 25} = Throttle.observe(Throttle.new(), headers, @now)
    end
  end

  describe "summary/1" do
    test "is nil before anything has been observed" do
      assert Throttle.summary(Throttle.new()) == nil
    end

    test "reports the percentage used" do
      throttle = Throttle.observe(Throttle.new(), business_usage(64), @now)

      assert Throttle.summary(throttle) == "64% of Meta's hourly allowance used"
    end
  end

  defp business_usage(percent, regain_minutes \\ 0) do
    payload =
      Jason.encode!(%{
        "17841400000000000" => [
          %{
            "type" => "instagram",
            "call_count" => percent,
            "total_cputime" => 1,
            "total_time" => 2,
            "estimated_time_to_regain_access" => regain_minutes
          }
        ]
      })

    %{"x-business-use-case-usage" => payload}
  end
end
