defmodule SmmMonitor.Fetchers.YouTube.QuotaTest do
  @moduledoc """
  The budget cutoff, which is what stops the tool spending its whole day's
  API allowance and then failing every call until midnight.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.YouTube.Quota

  doctest Quota

  # Mid-morning Pacific: 18:00Z is 10:00 PT, comfortably inside one day.
  @now ~U[2026-09-09 18:00:00Z]

  describe "check/3" do
    test "allows a call when there is budget" do
      assert :ok = Quota.check(Quota.new(8_000, @now), 100, @now)
    end

    test "allows the call that lands exactly on the budget" do
      quota = spend(Quota.new(8_000, @now), 79)

      assert quota.used == 7_900
      assert :ok = Quota.check(quota, 100, @now)
    end

    test "refuses the call that would exceed the budget" do
      # 80 searches x 100 units = the whole 8,000 budget.
      quota = spend(Quota.new(8_000, @now), 80)

      assert {:exhausted, wait_ms} = Quota.check(quota, 100, @now)
      assert wait_ms > 0
    end

    test "refuses a call that alone would overshoot a small budget" do
      assert {:exhausted, _ms} = Quota.check(Quota.new(50, @now), 100, @now)
    end

    test "the backoff runs to the end of the quota day" do
      quota = spend(Quota.new(8_000, @now), 80)
      {:exhausted, wait_ms} = Quota.check(quota, 100, @now)

      # 10:00 Pacific leaves 14 hours of the quota day.
      assert wait_ms == 14 * 3_600 * 1_000
    end
  end

  describe "spend/2" do
    test "accumulates units and call count" do
      quota = Quota.new(8_000, @now) |> Quota.spend(100) |> Quota.spend(100)

      assert quota.used == 200
      assert quota.calls == 2
    end
  end

  describe "remaining/1 and calls_remaining/2" do
    test "report what is left" do
      quota = spend(Quota.new(8_000, @now), 30)

      assert Quota.remaining(quota) == 5_000
      assert Quota.calls_remaining(quota, 100) == 50
    end

    test "never go negative" do
      quota = spend(Quota.new(8_000, @now), 100)

      assert Quota.remaining(quota) == 0
      assert Quota.calls_remaining(quota, 100) == 0
    end
  end

  describe "rollover/2" do
    test "resets the count on a new quota day" do
      spent = spend(Quota.new(8_000, @now), 80)
      tomorrow = DateTime.add(@now, 24 * 3_600, :second)

      rolled = Quota.rollover(spent, tomorrow)

      assert rolled.used == 0
      assert rolled.calls == 0
      assert :ok = Quota.check(rolled, 100, tomorrow)
    end

    test "leaves the count alone within the same quota day" do
      spent = spend(Quota.new(8_000, @now), 10)
      later = DateTime.add(@now, 3_600, :second)

      assert Quota.rollover(spent, later).used == 1_000
    end

    test "clears the once-a-day exhaustion log flag" do
      {false, quota} = spent_and_logged()
      tomorrow = DateTime.add(@now, 24 * 3_600, :second)

      refute Quota.rollover(quota, tomorrow).exhausted_logged
    end
  end

  describe "quota_day/1" do
    test "uses the Pacific boundary, not UTC" do
      # 03:00Z on the 10th is still 19:00 on the 9th in Pacific, so it
      # belongs to the previous quota day. Getting this wrong would reset
      # the budget eight hours early every night.
      assert Quota.quota_day(~U[2026-09-10 03:00:00Z]) == ~D[2026-09-09]
      assert Quota.quota_day(~U[2026-09-10 08:00:00Z]) == ~D[2026-09-10]
    end
  end

  describe "ms_until_reset/1" do
    test "counts down to the next Pacific midnight" do
      # 08:00Z is midnight Pacific exactly — a full day to go.
      assert Quota.ms_until_reset(~U[2026-09-09 08:00:00Z]) == 86_400_000
      assert Quota.ms_until_reset(~U[2026-09-09 20:00:00Z]) == 12 * 3_600 * 1_000
    end

    test "is always positive" do
      assert Quota.ms_until_reset(~U[2026-09-09 07:59:59Z]) > 0
    end
  end

  describe "mark_exhausted_logged/1" do
    test "reports the first call as not yet logged, then as logged" do
      # This is what keeps the stand-down message to once a day rather than
      # once per poll for the rest of the day.
      {first, quota} = Quota.mark_exhausted_logged(Quota.new(8_000, @now))
      {second, _quota} = Quota.mark_exhausted_logged(quota)

      refute first
      assert second
    end
  end

  describe "summary/1" do
    test "reads as budget usage" do
      quota = spend(Quota.new(8_000, @now), 20)

      assert Quota.summary(quota) == "2000/8000 units used today (60 searches left)"
    end
  end

  describe "search_cost/0" do
    test "is the documented 100 units" do
      assert Quota.search_cost() == 100
    end
  end

  defp spend(quota, calls),
    do: Enum.reduce(1..calls, quota, fn _i, acc -> Quota.spend(acc, 100) end)

  defp spent_and_logged do
    Quota.new(8_000, @now) |> spend(80) |> Quota.mark_exhausted_logged()
  end
end
