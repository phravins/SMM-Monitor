defmodule SmmMonitor.MonitorTest do
  @moduledoc """
  Tests the aggregation the dashboard reads: counts, sentiment tallies and
  the per-platform breakdown, across windows and platform filters.
  """

  use ExUnit.Case, async: false

  import SmmMonitor.Factory

  alias SmmMonitor.Monitor

  setup do
    Monitor.reset()
    :ok
  end

  describe "stats/2" do
    setup do
      Monitor.record_many([
        attrs(id: "p1", platform: :reddit, text: "great tool, would recommend", minutes_ago: 5),
        attrs(id: "p2", platform: :reddit, text: "excellent", minutes_ago: 10),
        attrs(id: "n1", platform: :reddit, text: "terrible and slow", minutes_ago: 15),
        attrs(id: "x1", platform: :youtube, text: "posted a walkthrough", minutes_ago: 20)
      ])

      :ok
    end

    test "aggregates counts and sentiment across every platform" do
      stats = Monitor.stats(:all)

      assert stats.count == 4
      assert stats.positive == 2
      assert stats.negative == 1
      assert stats.neutral == 1
      # +2 +1 -2 +0
      assert stats.score == 1
    end

    test "sentiment buckets always sum to the count" do
      stats = Monitor.stats(:all)
      assert stats.positive + stats.neutral + stats.negative == stats.count
    end

    test "filters by platform" do
      stats = Monitor.stats(:reddit)

      assert stats.count == 3
      assert stats.positive == 2
      assert stats.negative == 1
      assert stats.neutral == 0
      assert stats.platform == :reddit
    end

    test "reports zeroes for a platform with no mentions" do
      stats = Monitor.stats(:instagram)

      assert stats.count == 0
      assert stats.score == 0
      assert stats.positive == 0
    end

    test "respects an explicit window" do
      # A 12-minute window excludes the two older mentions.
      stats = Monitor.stats(:all, :timer.minutes(12))

      assert stats.count == 2
      assert stats.positive == 2
    end

    test "window: :all ignores age entirely" do
      Monitor.record(attrs(id: "ancient", minutes_ago: 60 * 24 * 30))

      assert Monitor.stats(:all, :all).count == 5
      assert Monitor.stats(:all, :timer.hours(24)).count == 4
    end

    test "echoes the window it used" do
      assert Monitor.stats(:all, :timer.minutes(5)).window_ms == :timer.minutes(5)
    end
  end

  describe "breakdown/1" do
    test "counts every configured platform, including quiet ones" do
      Monitor.record_many([
        attrs(id: "a", platform: :reddit),
        attrs(id: "b", platform: :reddit),
        attrs(id: "c", platform: :youtube)
      ])

      breakdown = Monitor.breakdown()

      assert breakdown[:reddit] == 2
      assert breakdown[:youtube] == 1
      # Present with a zero rather than missing, so the tab bar stays stable.
      assert breakdown[:twitter] == 0
      assert breakdown[:instagram] == 0
    end

    test "totals match the :all count" do
      Monitor.record_many([
        attrs(id: "a", platform: :reddit),
        attrs(id: "b", platform: :youtube),
        attrs(id: "c", platform: :twitter)
      ])

      assert breakdown_total() == Monitor.stats(:all).count
    end

    test "excludes mentions outside the window" do
      Monitor.record_many([
        attrs(id: "recent", platform: :reddit, minutes_ago: 1),
        attrs(id: "old", platform: :reddit, minutes_ago: 30)
      ])

      assert Monitor.breakdown(:timer.minutes(10))[:reddit] == 1
    end
  end

  describe "recent/2" do
    test "returns mentions newest first" do
      Monitor.record_many([
        attrs(id: "old", minutes_ago: 30),
        attrs(id: "new", minutes_ago: 1),
        attrs(id: "mid", minutes_ago: 15)
      ])

      assert ["new", "mid", "old"] = Enum.map(Monitor.recent(), & &1.id)
    end

    test "filters by platform and honours the limit" do
      Monitor.record_many([
        attrs(id: "r1", platform: :reddit, minutes_ago: 1),
        attrs(id: "r2", platform: :reddit, minutes_ago: 2),
        attrs(id: "y1", platform: :youtube, minutes_ago: 1)
      ])

      assert ["r1", "r2"] = Enum.map(Monitor.recent(:reddit), & &1.id)
      assert ["r1"] = Enum.map(Monitor.recent(:reddit, 1), & &1.id)
    end

    test "carries the sentiment assigned at ingest" do
      Monitor.record(attrs(id: "a", text: "really terrible experience"))

      assert [mention] = Monitor.recent()
      assert mention.sentiment == :negative
      assert mention.sentiment_value < 0
      assert mention.sentiment_score < 0
    end
  end

  describe "stats/2 sentiment" do
    test "reports the mean normalised score, not a total" do
      Monitor.record_many([
        attrs(id: "a", text: "excellent work"),
        attrs(id: "b", text: "excellent work again")
      ])

      stats = Monitor.stats()

      assert stats.average > 0
      # The mean must not climb just because more people said the same
      # thing: two identical raves score the same as one.
      Monitor.record_many([attrs(id: "c", text: "excellent work once more")])

      assert_in_delta Monitor.stats().average, stats.average, 0.001
    end

    test "is zero when there is nothing to average" do
      assert Monitor.stats().average == 0.0
      assert Monitor.stats().count == 0
    end
  end

  describe "record/1" do
    test "de-duplicates repeat mentions across polls" do
      # Two polls 30s apart re-see the same post; the count must not move.
      Monitor.record(attrs(id: "same", platform: :reddit))
      Monitor.record(attrs(id: "same", platform: :reddit))

      assert Monitor.stats(:reddit).count == 1
    end
  end

  defp breakdown_total, do: Monitor.breakdown() |> Map.values() |> Enum.sum()
end
