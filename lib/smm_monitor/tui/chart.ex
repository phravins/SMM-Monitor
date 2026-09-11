defmodule SmmMonitor.TUI.Chart do
  @moduledoc """
  Column charts for the trends screen, in plain text.

  Returns rows of `%{label, bars, style}` — a left-hand axis label, the
  row's glyphs, and which colour the renderer should paint them. No
  terminal library appears here, for the same reason none appears in
  `SmmMonitor.TUI.Model`: the charts are then drawable by both renderers
  and testable without a terminal.

  ## Why not Ratatouille's own chart widgets

  Both libraries ship a `sparkline` and an asciichart-backed `chart`, and
  neither fits this screen:

    * `sparkline` normalises over `min..max`, so a flat series divides by
      zero — a brand-new client, whose fortnight is fourteen zeros,
      crashes the dashboard. It is also one row tall, unlabelled and
      single-coloured.
    * `chart` plots a monochrome line. Sentiment's whole point is which
      side of zero it sits on, which is a colour, and a line chart of
      daily volume hides the zeros a bar chart shows plainly.

  Neither can label a column with its date, which is the first thing
  anyone asks of a spike. So the charts are drawn here — about a hundred
  lines, with the half-block trick below doing most of the work.

  ## Half blocks

  Each row is two levels rather than one: `█` fills a whole row, `▄`
  fills its lower half. Six rows of glyphs therefore resolve twelve
  levels, which is the difference between a chart where Tuesday and
  Wednesday look identical and one where they don't.
  """

  alias SmmMonitor.Trends

  @full "█"
  @half "▄"
  @upper_half "▀"

  # Wider columns for a short window: seven days across sixty characters
  # as single bars looks like a mistake rather than a week.
  @widths %{7 => 3, 14 => 2}
  @default_width 1

  @type row :: %{label: String.t(), bars: String.t(), style: atom()}

  @doc """
  Mention volume per day, growing up from a baseline.

      iex> alias SmmMonitor.TUI.Chart
      iex> days = [%{date: ~D[2026-09-09], count: 4}, %{date: ~D[2026-09-10], count: 0},
      ...>         %{date: ~D[2026-09-11], count: 2}]
      iex> Chart.volume(days, height: 2) |> Enum.map(&(&1.label <> &1.bars))
      ["  4 ┤██      ", "    ┤██    ██", "  0 └─────────", "    9 Sep 11 Sep"]

  The tallest column is the window's busiest day, so the chart always
  fills its height — the shape is the point, not the absolute height,
  and the axis carries the number for anyone who wants it.
  """
  @spec volume([Trends.day()], keyword()) :: [row()]
  def volume(days, opts \\ [])

  def volume([], _opts), do: []

  def volume(days, opts) do
    height = Keyword.get(opts, :height, 6)
    width = column_width(days, opts)
    counts = Enum.map(days, & &1.count)
    peak = Enum.max(counts)
    scale = max(peak, 1)

    rows =
      for row <- (height - 1)..0//-1 do
        %{
          label: axis_label(row, height, peak),
          bars: Enum.map_join(counts, " ", &cell(level(&1, scale, height), row, width)),
          style: :volume
        }
      end

    rows ++ [baseline(days, width, "  0 └"), date_axis(days, width)]
  end

  @doc """
  Average sentiment per day, growing out from a zero line.

  Positive days rise above the line and negative days fall below it, so
  a bad week is visible from across the room without reading a number.

      iex> alias SmmMonitor.TUI.Chart
      iex> days = [%{date: ~D[2026-09-10], count: 3, average: 0.8},
      ...>         %{date: ~D[2026-09-11], count: 2, average: -0.4}]
      iex> Chart.sentiment(days, height: 1) |> Enum.map(&{&1.style, &1.label <> &1.bars})
      [{:positive, " +1 ┤██   "}, {:axis, "  0 ┼─────"}, {:negative, " -1 ┤   ██"},
       {:muted, "    10 Sep 11 Sep"}]
  """
  @spec sentiment([Trends.day()], keyword()) :: [row()]
  def sentiment(days, opts \\ [])

  def sentiment([], _opts), do: []

  def sentiment(days, opts) do
    height = Keyword.get(opts, :height, 3)
    width = column_width(days, opts)
    values = Enum.map(days, & &1.average)

    above =
      for row <- (height - 1)..0//-1 do
        %{
          label: sentiment_label(row, height, :above),
          bars: Enum.map_join(values, " ", &cell(level(max(&1, 0.0), 1.0, height), row, width)),
          style: :positive
        }
      end

    below =
      for row <- 0..(height - 1)//1 do
        %{
          label: sentiment_label(row, height, :below),
          bars:
            Enum.map_join(
              values,
              " ",
              &inverted_cell(level(max(-&1, 0.0), 1.0, height), row, width)
            ),
          style: :negative
        }
      end

    above ++ [zero_line(days, width)] ++ below ++ [date_axis(days, width)]
  end

  @doc """
  The width in characters a chart of this many days will occupy.

  The screen uses it to decide whether the window still fits the
  terminal it is being drawn in.
  """
  @spec width([Trends.day()] | non_neg_integer(), keyword()) :: non_neg_integer()
  def width(days, opts \\ [])
  def width(days, opts) when is_list(days), do: width(length(days), opts)
  def width(0, _opts), do: 0

  def width(count, opts) do
    column = Keyword.get(opts, :width) || Map.get(@widths, count, @default_width)
    count * column + (count - 1)
  end

  # --- internals ------------------------------------------------------------

  defp column_width(days, opts) do
    Keyword.get(opts, :width) || Map.get(@widths, length(days), @default_width)
  end

  # Two levels per row: `█` is both halves, `▄` the lower one.
  defp level(0, _max, _height), do: 0
  defp level(+0.0, _max, _height), do: 0

  defp level(value, max, height) do
    levels = height * 2
    scaled = round(value / max * levels)

    # A day that happened should never be invisible, however small it is
    # next to the peak: a fortnight where one day had 400 mentions and
    # the rest had 3 is still a fortnight with mentions on it.
    scaled |> min(levels) |> max(1)
  end

  defp cell(level, row, width) do
    cond do
      level >= (row + 1) * 2 -> String.duplicate(@full, width)
      level == row * 2 + 1 -> String.duplicate(@half, width)
      true -> String.duplicate(" ", width)
    end
  end

  # The mirror image, for bars hanging below a zero line: the half block
  # has to cling to the top of its row rather than the bottom.
  defp inverted_cell(level, row, width) do
    cond do
      level >= (row + 1) * 2 -> String.duplicate(@full, width)
      level == row * 2 + 1 -> String.duplicate(@upper_half, width)
      true -> String.duplicate(" ", width)
    end
  end

  # The top of the axis is the busiest day, and a third of the way up is
  # enough of a second mark to read the middle of the chart by. A window
  # with nothing in it gets one honest zero rather than a scale invented
  # for bars that aren't there.
  defp axis_label(_row, _height, 0), do: "    ┤"

  defp axis_label(row, height, peak) do
    cond do
      row == height - 1 -> pad(peak)
      row == 0 and height > 2 -> pad(max(div(peak, height), 1))
      true -> "    ┤"
    end
  end

  defp pad(value), do: String.pad_leading(to_string(value), 3) <> " ┤"

  defp sentiment_label(row, height, :above) do
    if row == height - 1, do: " +1 ┤", else: "    ┤"
  end

  defp sentiment_label(row, height, :below) do
    if row == height - 1, do: " -1 ┤", else: "    ┤"
  end

  defp zero_line(days, width) do
    %{label: "  0 ┼", bars: String.duplicate("─", width(days, width: width)), style: :axis}
  end

  defp baseline(days, width, label) do
    %{label: label, bars: String.duplicate("─", width(days, width: width)), style: :axis}
  end

  # Enough dates to place a spike, never enough to crowd the columns:
  # the ends always, and the middle once the window is wide enough for
  # the three to sit apart.
  defp date_axis(days, width) do
    span = width(days, width: width)
    first = days |> List.first() |> label_for()
    last = days |> List.last() |> label_for()

    bars =
      if length(days) >= 10 do
        middle = days |> Enum.at(div(length(days), 2)) |> label_for()

        first
        |> pad_to(div(span, 2) - div(String.length(middle), 2))
        |> Kernel.<>(middle)
        |> pad_to(span - String.length(last))
        |> Kernel.<>(last)
      else
        first |> pad_to(span - String.length(last)) |> Kernel.<>(last)
      end

    %{label: "    ", bars: bars, style: :muted}
  end

  defp label_for(%{date: date}), do: Calendar.strftime(date, "%-d %b")

  defp pad_to(text, width) when width > 0, do: String.pad_trailing(text, width)
  defp pad_to(text, _width), do: text <> " "
end
