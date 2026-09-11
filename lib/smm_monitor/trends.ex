defmodule SmmMonitor.Trends do
  @moduledoc """
  A client's history, day by day.

  The dashboard's other screens answer "what is being said right now".
  This one answers "is this getting better or worse", which needs the
  weeks behind it rather than the hours: mention volume per day and
  average sentiment per day, over a window the viewer can widen.

  ## Where the numbers come from

  The durable log, grouped by day *in SQL* (`Persistence.daily_stats/3`).
  ETS holds hours, not weeks, so it cannot answer this at all; and
  loading a month of mentions to count them in Elixir would read
  thousands of rows to produce thirty numbers, on a screen that
  refreshes while you watch it.

  ## Silent days are data

  The series is zero-filled from the window's own dates rather than
  built from whatever the database happened to return, so a day with no
  mentions is a zero in the chart instead of a gap in it — the shape of
  a quiet week is the thing you came to the screen to see.
  """

  alias SmmMonitor.Persistence
  alias SmmMonitor.Reports.Period

  # 7, 14, 30: a week, a fortnight, a month. Wide enough apart to answer
  # different questions, few enough to cycle through with one key.
  @windows [7, 14, 30]
  @default_window 14

  defstruct client_id: nil,
            window_days: @default_window,
            period: nil,
            # One entry per day in the window, oldest first.
            days: [],
            total: 0,
            # Mean of every mention in the window, not the mean of the
            # daily means: a day with two mentions should not weigh as
            # much as a day with two hundred.
            average: 0.0,
            busiest: nil,
            worst: nil,
            best: nil,
            generated_at: nil

  @type day :: %{
          date: Date.t(),
          count: non_neg_integer(),
          average: float(),
          positive: non_neg_integer(),
          neutral: non_neg_integer(),
          negative: non_neg_integer()
        }

  @type t :: %__MODULE__{}

  @doc "The window sizes the screen cycles through."
  @spec windows() :: [pos_integer()]
  def windows, do: @windows

  @doc "The window a session starts on."
  @spec default_window() :: pos_integer()
  def default_window, do: @default_window

  @doc """
  The next window size, wrapping at the end.

      iex> alias SmmMonitor.Trends
      iex> {Trends.next_window(7), Trends.next_window(14), Trends.next_window(30)}
      {14, 30, 7}

  An unknown size — a config file edited by hand, or a window from an
  older version — lands on the default rather than getting stuck.

      iex> SmmMonitor.Trends.next_window(21)
      14
  """
  @spec next_window(pos_integer()) :: pos_integer()
  def next_window(current), do: step(current, 1)

  @doc """
  The previous window size, wrapping at the start.

      iex> alias SmmMonitor.Trends
      iex> {Trends.previous_window(30), Trends.previous_window(14), Trends.previous_window(7)}
      {14, 7, 30}
  """
  @spec previous_window(pos_integer()) :: pos_integer()
  def previous_window(current), do: step(current, -1)

  defp step(current, delta) do
    case Enum.find_index(@windows, &(&1 == current)) do
      nil -> @default_window
      index -> Enum.at(@windows, rem(index + delta + length(@windows), length(@windows)))
    end
  end

  @doc """
  Builds the series for one client.

  Options: `:days` (window size, default 14), `:today` (for tests),
  and anything `Persistence.daily_stats/3` takes — `:platform` scopes
  the series to one platform, `:repo` to another repo.

  A `nil` client id gives an empty series rather than every client's
  mentions added together: an install with no clients should show an
  empty chart, not a meaningless one.
  """
  @spec for_client(String.t() | nil, keyword()) :: t()
  def for_client(client_id, opts \\ [])

  def for_client(nil, opts), do: %__MODULE__{window_days: window(opts), generated_at: now(opts)}

  def for_client(client_id, opts) do
    days = window(opts)
    period = Period.last_days(days, Keyword.get(opts, :today, Date.utc_today()))

    series =
      period.from
      |> Persistence.daily_stats(period.to, Keyword.put(opts, :client, client_id))
      |> fill(period)

    %__MODULE__{
      client_id: client_id,
      window_days: days,
      period: period,
      days: series,
      total: Enum.sum(Enum.map(series, & &1.count)),
      average: weighted_average(series),
      busiest: busiest(series),
      worst: extreme(series, :worst),
      best: extreme(series, :best),
      generated_at: now(opts)
    }
  end

  @doc "The largest daily count in the window, which is what the volume chart scales to."
  @spec peak(t()) :: non_neg_integer()
  def peak(%__MODULE__{days: []}), do: 0
  def peak(%__MODULE__{days: days}), do: days |> Enum.map(& &1.count) |> Enum.max()

  @doc "Days in the window that had at least one mention."
  @spec active_days(t()) :: non_neg_integer()
  def active_days(%__MODULE__{days: days}), do: Enum.count(days, &(&1.count > 0))

  @doc "Mentions per day across the whole window, silent days included."
  @spec per_day(t()) :: float()
  def per_day(%__MODULE__{days: []}), do: 0.0
  def per_day(%__MODULE__{total: total, days: days}), do: Float.round(total / length(days), 1)

  @doc "Whether there is anything at all to draw."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{total: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  # --- internals ------------------------------------------------------------

  defp window(opts) do
    case Keyword.get(opts, :days, @default_window) do
      days when is_integer(days) and days > 0 -> days
      _other -> @default_window
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())

  # Driven by the period's dates, not by the rows: the database only
  # returns days that had mentions, and the gaps between them are half
  # of what the chart is for.
  defp fill(rows, period) do
    by_date = Map.new(rows, &{&1.date, &1})

    Enum.map(Period.dates(period), fn date ->
      Map.get(by_date, date, %{
        date: date,
        count: 0,
        average: 0.0,
        positive: 0,
        neutral: 0,
        negative: 0
      })
    end)
  end

  defp weighted_average([]), do: 0.0

  defp weighted_average(series) do
    total = Enum.sum(Enum.map(series, & &1.count))

    if total == 0 do
      0.0
    else
      series
      |> Enum.map(&(&1.average * &1.count))
      |> Enum.sum()
      |> Kernel./(total)
      |> Float.round(3)
    end
  end

  defp busiest([]), do: nil

  defp busiest(series) do
    case Enum.max_by(series, & &1.count) do
      %{count: 0} -> nil
      day -> day
    end
  end

  # Only days with mentions can be the best or the worst: a silent day
  # averages 0.0, which would otherwise read as the most neutral day of
  # a bad week and win.
  defp extreme(series, which) do
    spoken = Enum.filter(series, &(&1.count > 0))

    case {spoken, which} do
      {[], _which} -> nil
      {days, :worst} -> Enum.min_by(days, & &1.average)
      {days, :best} -> Enum.max_by(days, & &1.average)
    end
  end
end
