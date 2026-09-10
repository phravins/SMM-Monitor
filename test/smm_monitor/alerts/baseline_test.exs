defmodule SmmMonitor.Alerts.BaselineTest do
  @moduledoc """
  What a normal hour looks like for a client.

  The point of the same-hour baseline is that brands have a daily
  rhythm: a flat weekly average says a Tuesday lunchtime and a Sunday
  night should look alike, which alerts every weekday morning and misses
  a genuine weekend storm.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Baseline

  doctest Baseline

  @now ~U[2026-09-12 09:30:00Z]

  describe "same_hour/3" do
    test "averages the same clock hour on previous days" do
      timestamps =
        at(1, ~T[09:05:00]) ++
          at(1, ~T[09:45:00]) ++
          at(2, ~T[09:15:00]) ++
          at(3, ~T[09:55:00])

      baseline = Baseline.same_hour(timestamps, @now, 7)

      # Two mentions yesterday, one the day before, one before that.
      assert baseline.samples == [0, 0, 0, 0, 1, 1, 2]
      assert baseline.average == 1.33
      assert baseline.days_observed == 3
    end

    test "ignores mentions from other hours of the day" do
      # The whole reason for the same-hour baseline: a busy afternoon
      # says nothing about what a normal 9am looks like.
      timestamps = at(1, ~T[15:00:00]) ++ at(1, ~T[03:00:00]) ++ at(2, ~T[09:30:00])

      baseline = Baseline.same_hour(timestamps, @now, 7)

      assert baseline.average == 1.0
      assert baseline.days_observed == 1
    end

    test "excludes the current window, so a spike can't raise its own baseline" do
      # Twenty mentions in the last few minutes must not become "normal".
      timestamps = List.duplicate(~U[2026-09-12 09:29:00Z], 20)

      baseline = Baseline.same_hour(timestamps, @now, 7)

      assert baseline.average == 0.0
      assert baseline.days_observed == 0
    end

    test "counts a whole clock hour regardless of the current minute" do
      # 09:00:00 to 09:59:59, not a rolling window anchored on 09:30.
      timestamps = at(1, ~T[09:00:00]) ++ at(1, ~T[09:59:00])

      assert Baseline.same_hour(timestamps, @now, 7).samples |> Enum.sum() == 2
    end

    test "a mention on the hour boundary belongs to the later hour" do
      before_hour = at(1, ~T[08:59:59])
      on_hour = at(1, ~T[10:00:00])

      assert Baseline.same_hour(before_hour ++ on_hour, @now, 7).samples |> Enum.sum() == 0
    end
  end

  describe "reading a short history honestly" do
    test "a client with two days of history is averaged over two days" do
      # Dividing by seven would count four days that never happened and
      # make an ordinary hour look like a spike.
      timestamps = at(1, ~T[09:10:00]) ++ at(1, ~T[09:20:00]) ++ at(2, ~T[09:30:00])

      baseline = Baseline.same_hour(timestamps, @now, 7)

      assert baseline.days_observed == 2
      assert baseline.average == 1.5
    end

    test "no history at all is zero days observed, not a zero baseline" do
      baseline = Baseline.same_hour([], @now, 7)

      assert baseline.days_observed == 0
      assert baseline.average == 0.0
    end

    test "the caller can tell a quiet client from a new one" do
      # Both have a low average; only one has days behind it. This is
      # what the volume condition refuses to alert on.
      new_client = Baseline.same_hour(at(1, ~T[09:00:00]), @now, 7)
      established = Baseline.same_hour(Enum.flat_map(1..7, &at(&1, ~T[09:00:00])), @now, 7)

      assert new_client.days_observed == 1
      assert established.days_observed == 7
      assert new_client.average == established.average
    end

    test "only as many days as asked for are looked at" do
      timestamps = Enum.flat_map(1..10, &at(&1, ~T[09:00:00]))

      assert Baseline.same_hour(timestamps, @now, 3).days_observed == 3
    end
  end

  describe "ratio/2" do
    test "is how many times above normal the observation is" do
      assert Baseline.ratio(12, 3.0) == 4.0
    end

    test "a client with no usual level at this hour is an infinite ratio" do
      # Not a rounding artefact: a brand that normally has nothing at 3am
      # suddenly having twenty is the clearest signal there is.
      assert Baseline.ratio(20, 0.0) == :infinity
    end

    test "nothing observed is never a spike, even against a zero baseline" do
      assert Baseline.ratio(0, 0.0) == 0.0
    end
  end

  # `count` mentions `days_ago` days before @now, at the given time.
  defp at(days_ago, time, count \\ 1) do
    date = Date.add(~D[2026-09-12], -days_ago)
    {:ok, naive} = NaiveDateTime.new(date, time)
    {:ok, timestamp} = DateTime.from_naive(naive, "Etc/UTC")
    List.duplicate(timestamp, count)
  end
end
