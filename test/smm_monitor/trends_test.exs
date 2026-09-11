defmodule SmmMonitor.TrendsTest do
  @moduledoc """
  The day-by-day series behind the trends screen.

  Fixtures are stored with known timestamps and known scores, and the
  expected series is written out in full: the point of this screen is
  that the shape of the chart can be trusted, and a chart is only as
  honest as the grouping under it.
  """

  use SmmMonitor.DatabaseCase, async: true

  alias SmmMonitor.Trends

  doctest Trends

  @today ~D[2026-09-11]

  describe "volume per day" do
    test "counts each day separately" do
      store("acme", ~D[2026-09-09], 3)
      store("acme", ~D[2026-09-10], 1)
      store("acme", ~D[2026-09-11], 2)

      assert counts("acme", 3) == [3, 1, 2]
    end

    test "fills a silent day with a zero rather than leaving a gap" do
      store("acme", ~D[2026-09-05], 2)
      store("acme", ~D[2026-09-11], 1)

      assert counts("acme", 7) == [2, 0, 0, 0, 0, 0, 1]
    end

    test "is all zeros for a client that has never been mentioned" do
      assert counts("acme", 7) == [0, 0, 0, 0, 0, 0, 0]
    end

    test "returns one entry per day of the window, whatever the data" do
      store("acme", ~D[2026-09-11], 1)

      for window <- [7, 14, 30] do
        assert length(counts("acme", window)) == window
      end
    end

    test "runs oldest first, the direction the chart is drawn in" do
      trends = build("acme", 7)

      assert Enum.map(trends.days, & &1.date) |> List.first() == ~D[2026-09-05]
      assert Enum.map(trends.days, & &1.date) |> List.last() == @today
    end

    test "counts a mention posted just before midnight on the day it was posted" do
      # Grouping on the collection time instead would move late-evening
      # mentions into the next day, and a spike would land on the wrong
      # column.
      store_at("acme", ~U[2026-09-10 23:59:30Z])

      assert counts("acme", 7) == [0, 0, 0, 0, 0, 1, 0]
    end

    test "leaves out a day that falls before the window" do
      store("acme", ~D[2026-09-04], 5)
      store("acme", ~D[2026-09-11], 1)

      assert counts("acme", 7) == [0, 0, 0, 0, 0, 0, 1]
    end

    test "counts only the client asked about" do
      store("acme", ~D[2026-09-11], 2)
      store("globex", ~D[2026-09-11], 7)

      assert counts("acme", 7) |> List.last() == 2
      assert counts("globex", 7) |> List.last() == 7
    end

    test "can be narrowed to one platform" do
      store("acme", ~D[2026-09-11], 2, platform: :reddit)
      store("acme", ~D[2026-09-11], 1, platform: :youtube)

      trends = Trends.for_client("acme", days: 7, today: @today, platform: :youtube)

      assert Enum.map(trends.days, & &1.count) |> List.last() == 1
    end

    test "with no client selected, shows nothing rather than everyone added together" do
      store("acme", ~D[2026-09-11], 2)
      store("globex", ~D[2026-09-11], 7)

      trends = Trends.for_client(nil, days: 7, today: @today)

      assert trends.days == []
      assert trends.total == 0
    end
  end

  describe "average sentiment per day" do
    test "averages within the day" do
      store_scored("acme", ~D[2026-09-10], [1.0, 0.0])
      store_scored("acme", ~D[2026-09-11], [-0.5, -0.1])

      assert averages("acme", 2) == [0.5, -0.3]
    end

    test "a silent day is zero, and says so with a zero count beside it" do
      store_scored("acme", ~D[2026-09-11], [0.8])

      [quiet, spoken] = build("acme", 2).days

      assert {quiet.count, quiet.average} == {0, 0.0}
      assert {spoken.count, spoken.average} == {1, 0.8}
    end

    test "splits the day by label as well as by score" do
      store_scored("acme", ~D[2026-09-11], [0.7, 0.0, -0.9, -0.2])

      day = build("acme", 1).days |> List.last()

      assert {day.positive, day.neutral, day.negative} == {1, 1, 2}
    end

    test "ignores rows scored before sentiment was numeric" do
      # A null score means "we never worked it out", and inventing one
      # would move the line without anybody having said anything.
      store_scored("acme", ~D[2026-09-11], [0.6])
      store_at("acme", ~U[2026-09-11 10:00:00Z], sentiment_value: nil)

      day = build("acme", 1).days |> List.last()

      assert day.count == 2
      assert day.average == 0.6
    end
  end

  describe "the window's headline figures" do
    setup do
      store_scored("acme", ~D[2026-09-09], [0.5, 0.5, 0.5, 0.5])
      store_scored("acme", ~D[2026-09-10], [-1.0])
      store_scored("acme", ~D[2026-09-11], [0.1])

      %{trends: build("acme", 7)}
    end

    test "total is every mention in the window", %{trends: trends} do
      assert trends.total == 6
    end

    test "the average weighs mentions, not days", %{trends: trends} do
      # The mean of the daily means would be -0.13 and would let one
      # grumpy Thursday outweigh a busy, happy Wednesday.
      assert trends.average == Float.round((0.5 * 4 - 1.0 + 0.1) / 6, 3)
    end

    test "the peak is what the volume chart scales to", %{trends: trends} do
      assert Trends.peak(trends) == 4
      assert trends.busiest.date == ~D[2026-09-09]
    end

    test "per-day counts the silent days too", %{trends: trends} do
      assert Trends.per_day(trends) == Float.round(6 / 7, 1)
    end

    test "active days are the ones anybody spoke on", %{trends: trends} do
      assert Trends.active_days(trends) == 3
    end

    test "best and worst days ignore the silent ones", %{trends: trends} do
      # A silent day averages 0.0, which would otherwise win "best day"
      # in a bad week and lose "worst day" in a good one.
      assert trends.worst.date == ~D[2026-09-10]
      assert trends.best.date == ~D[2026-09-09]
    end
  end

  describe "an empty window" do
    test "has no peak, no best and no worst rather than a misleading one" do
      trends = build("acme", 7)

      assert Trends.empty?(trends)
      assert Trends.peak(trends) == 0
      assert trends.busiest == nil
      assert trends.best == nil
      assert trends.worst == nil
      assert trends.average == 0.0
      assert Trends.per_day(trends) == 0.0
    end
  end

  describe "window sizes" do
    test "the default is a fortnight — two weekends and the week between" do
      assert Trends.default_window() == 14
      assert Trends.for_client("acme").window_days == 14
    end

    test "cycling forward wraps back to the start" do
      assert Trends.windows() == [7, 14, 30]
      assert 7 |> Trends.next_window() |> Trends.next_window() |> Trends.next_window() == 7
    end

    test "cycling back is the exact inverse" do
      for window <- Trends.windows() do
        assert window |> Trends.next_window() |> Trends.previous_window() == window
      end
    end

    test "a size from somewhere else lands on the default rather than sticking" do
      assert Trends.next_window(99) == 14
      assert Trends.previous_window(0) == 14
    end

    test "a nonsense window falls back instead of querying a negative range" do
      assert Trends.for_client("acme", days: 0).window_days == 14
      assert Trends.for_client("acme", days: "lots").window_days == 14
    end
  end

  # --- helpers --------------------------------------------------------------

  defp build(client_id, days), do: Trends.for_client(client_id, days: days, today: @today)

  defp counts(client_id, days), do: build(client_id, days).days |> Enum.map(& &1.count)

  defp averages(client_id, days), do: build(client_id, days).days |> Enum.map(& &1.average)

  defp store(client_id, date, count, overrides \\ []) do
    for n <- 1..count do
      store_at(client_id, noon(date, n), overrides)
    end
  end

  defp store_scored(client_id, date, values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      store_at(client_id, noon(date, index),
        sentiment_value: value,
        sentiment: label(value)
      )
    end)
  end

  defp store_at(client_id, timestamp, overrides \\ []) do
    attrs =
      [client_id: client_id, timestamp: timestamp]
      |> Keyword.merge(overrides)

    {:ok, 1} = Persistence.store([mention(attrs)])
  end

  defp noon(date, offset) do
    DateTime.new!(date, ~T[12:00:00], "Etc/UTC") |> DateTime.add(offset, :minute)
  end

  defp label(value) when value > 0.05, do: :positive
  defp label(value) when value < -0.05, do: :negative
  defp label(_value), do: :neutral
end
