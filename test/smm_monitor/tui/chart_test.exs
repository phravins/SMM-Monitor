defmodule SmmMonitor.TUI.ChartTest do
  @moduledoc """
  The trends screen's two charts, as text.

  Charts are the easiest thing in a dashboard to get subtly wrong —
  a bar one row short, a negative day drawn above the line, a quiet day
  indistinguishable from a busy one — and the hardest to notice, because
  a wrong chart still looks like a chart. So these tests read the glyphs.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.TUI.Chart

  doctest Chart

  describe "volume/2" do
    test "gives every day a column, in order" do
      rows = Chart.volume(days([1, 2, 3]), height: 2, width: 1)

      assert text(rows) == [
               "  3 ┤  ▄ █",
               "    ┤▄ █ █",
               "  0 └─────",
               "    9 Sep 11 Sep"
             ]
    end

    test "scales to the busiest day, so the chart always fills its height" do
      # The shape is what the screen is for; the axis carries the number
      # for anyone who wants the absolute height. A quiet week and a
      # frantic one in the same proportions draw the same picture.
      busy = Chart.volume(days([100, 200, 50]), height: 3, width: 1)
      quiet = Chart.volume(days([2, 4, 1]), height: 3, width: 1)

      assert bars(busy) == bars(quiet)
      assert hd(busy).label =~ "200"
      assert hd(quiet).label =~ "4"
    end

    test "a day with nothing on it is blank, not a stub" do
      rows = Chart.volume(days([4, 0, 4]), height: 2, width: 1)

      assert bars(rows) |> hd() == "█   █"
    end

    test "a day that happened is never invisible, however small" do
      # One mention next to a day of four hundred still rounds to
      # nothing without this, and a fortnight with a single quiet
      # Tuesday would look like a fortnight with no Tuesday.
      rows = Chart.volume(days([400, 1]), height: 3, width: 1)

      assert rows |> Enum.filter(&(&1.style == :volume)) |> List.last() |> Map.fetch!(:bars) ==
               "█ ▄"
    end

    test "half blocks double the resolution of the same height" do
      # Three and four mentions must not draw identically just because
      # the chart is only a few rows tall.
      three = Chart.volume(days([6, 3]), height: 3, width: 1) |> bars()
      four = Chart.volume(days([6, 4]), height: 3, width: 1) |> bars()

      refute three == four
    end

    test "ends with a baseline and a date axis" do
      rows = Chart.volume(days([1, 2, 3]), height: 4, width: 1)

      assert length(rows) == 6
      assert Enum.at(rows, -2).style == :axis
      assert Enum.at(rows, -1).style == :muted
      assert Enum.at(rows, -1).bars =~ "11 Sep"
    end

    test "labels the ends of the window, and the middle once it is wide enough" do
      short = Chart.volume(days([1, 2, 3]), height: 2, width: 1) |> List.last()
      long = Chart.volume(days(List.duplicate(1, 14)), height: 2, width: 1) |> List.last()

      refute short.bars =~ "10 Sep"
      assert long.bars =~ "5 Sep"
    end

    test "draws nothing at all for a window with no days in it" do
      assert Chart.volume([], height: 4) == []
    end

    test "survives a client who has never been mentioned" do
      # Ratatouille's own sparkline divides by zero on a flat series, so
      # a brand-new client's fortnight of zeros would take the dashboard
      # down. This is the case that ruled it out.
      rows = Chart.volume(days([0, 0, 0, 0]), height: 3, width: 1)

      assert bars(rows) |> Enum.take(3) |> Enum.all?(&(String.trim(&1) == ""))
      assert hd(rows).label == "    ┤"
    end

    test "widens its columns when asked" do
      [row | _] = Chart.volume(days([1, 1]), height: 1, width: 3)

      assert row.bars == "███ ███"
    end
  end

  describe "sentiment/2" do
    test "puts a good day above the line and a bad one below it" do
      rows = Chart.sentiment(scored([0.8, -0.8]), height: 1, width: 1)

      assert text(rows) == [
               " +1 ┤█  ",
               "  0 ┼───",
               " -1 ┤  █",
               "    10 Sep 11 Sep"
             ]
    end

    test "colours the halves differently, which is the whole point" do
      rows = Chart.sentiment(scored([0.5, -0.5]), height: 2, width: 1)
      styles = Enum.map(rows, & &1.style)

      assert styles == [:positive, :positive, :axis, :negative, :negative, :muted]
    end

    test "is symmetrical about the zero line" do
      rows = Chart.sentiment(scored([0.6, -0.6]), height: 3, width: 1)

      above = rows |> Enum.filter(&(&1.style == :positive)) |> Enum.map(& &1.bars)
      below = rows |> Enum.filter(&(&1.style == :negative)) |> Enum.map(& &1.bars)

      assert length(above) == length(below)
      assert above |> Enum.join() |> String.replace("█", "") |> String.trim() == ""
      assert Enum.count(above, &(&1 =~ "█")) == Enum.count(below, &(&1 =~ "█"))
    end

    test "hangs a half block from the top of its row, below the line" do
      # A half block sitting on the floor of its row would leave a gap
      # between the bar and the zero line it is supposed to hang from.
      rows = Chart.sentiment(scored([-0.3]), height: 2, width: 1)

      assert rows |> Enum.find(&(&1.style == :negative)) |> Map.fetch!(:bars) == "▀"
    end

    test "is fixed to the -1..+1 scale rather than the week's own range" do
      # A week where nothing moved much must look flat, not dramatic:
      # rescaling to the data would turn a rounding error into a crisis.
      calm = Chart.sentiment(scored([0.02, -0.02]), height: 3, width: 1)
      stormy = Chart.sentiment(scored([1.0, -1.0]), height: 3, width: 1)

      refute bars(calm) == bars(stormy)
      assert glyphs(calm) == "▄▀"
      assert glyphs(stormy) == "██████"
    end

    test "a day that was spoken about but scored flat still shows on its side" do
      assert Chart.sentiment(scored([0.05]), height: 2, width: 1)
             |> Enum.filter(&(&1.style == :positive))
             |> List.last()
             |> Map.fetch!(:bars) == "▄"
    end

    test "draws the axis and nothing else for a silent window" do
      rows = Chart.sentiment(scored([0.0, 0.0]), height: 2, width: 1)

      assert Enum.find(rows, &(&1.style == :axis)).bars == "───"
      assert glyphs(rows) == ""
    end

    test "draws nothing at all for a window with no days in it" do
      assert Chart.sentiment([], height: 2) == []
    end
  end

  describe "width/2" do
    test "is what the chart will actually occupy" do
      rows = Chart.volume(days([1, 2, 3]), height: 2, width: 2)

      assert Chart.width(3, width: 2) == 8
      assert String.length(Enum.at(rows, -2).bars) == Chart.width(3, width: 2)
    end

    test "counts the gaps between columns, not just the columns" do
      assert Chart.width(10, width: 1) == 19
      assert Chart.width(30, width: 2) == 89
    end

    test "is nothing for an empty window" do
      assert Chart.width([], width: 3) == 0
    end
  end

  # --- helpers --------------------------------------------------------------

  defp days(counts) do
    counts
    |> Enum.with_index()
    |> Enum.map(fn {count, index} ->
      %{
        date: Date.add(~D[2026-09-11], index - (length(counts) - 1)),
        count: count,
        average: 0.0
      }
    end)
  end

  defp scored(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      %{
        date: Date.add(~D[2026-09-11], index - (length(values) - 1)),
        count: 1,
        average: value
      }
    end)
  end

  defp text(rows), do: Enum.map(rows, &(&1.label <> &1.bars))

  # Just the bar glyphs, with the axis and the date row left out.
  defp glyphs(rows) do
    rows
    |> Enum.reject(&(&1.style in [:axis, :muted]))
    |> Enum.map_join(& &1.bars)
    |> String.replace(" ", "")
  end

  defp bars(rows), do: Enum.map(rows, & &1.bars)
end
