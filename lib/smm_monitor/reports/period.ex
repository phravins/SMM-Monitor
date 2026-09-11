defmodule SmmMonitor.Reports.Period do
  @moduledoc """
  The stretch of time a report covers, and the one before it.

  A report is always about a *period*, and every number in it is only
  meaningful next to the same number from the period before — "412
  mentions" says nothing; "412, up from 280" says something. So a period
  knows how to produce its own predecessor, of exactly the same length,
  ending where it begins.

  Boundaries are whole days in UTC: a client asking for "last 7 days"
  means seven calendar days, not 168 hours ending at 14:32.
  """

  @enforce_keys [:from, :to, :label]
  defstruct [:from, :to, :label, :days]

  @type t :: %__MODULE__{
          from: DateTime.t(),
          to: DateTime.t(),
          label: String.t(),
          days: pos_integer()
        }

  @doc """
  The `days` whole days ending at the end of `today`.

      iex> period = SmmMonitor.Reports.Period.last_days(7, ~D[2026-09-11])
      iex> {DateTime.to_date(period.from), DateTime.to_date(period.to), period.label}
      {~D[2026-09-05], ~D[2026-09-11], "last 7 days"}
  """
  @spec last_days(pos_integer(), Date.t()) :: t()
  def last_days(days, today \\ Date.utc_today()) when days > 0 do
    from = Date.add(today, -(days - 1))

    %__MODULE__{
      from: start_of_day(from),
      to: end_of_day(today),
      label: "last #{days} days",
      days: days
    }
  end

  @doc """
  An explicit date range, inclusive of both ends.

      iex> {:ok, period} = SmmMonitor.Reports.Period.between(~D[2026-09-01], ~D[2026-09-07])
      iex> {period.days, period.label}
      {7, "1 Sep 2026 to 7 Sep 2026"}
  """
  @spec between(Date.t(), Date.t()) :: {:ok, t()} | {:error, :inverted_range}
  def between(from, to) do
    if Date.compare(from, to) == :gt do
      {:error, :inverted_range}
    else
      days = Date.diff(to, from) + 1

      {:ok,
       %__MODULE__{
         from: start_of_day(from),
         to: end_of_day(to),
         label: "#{format(from)} to #{format(to)}",
         days: days
       }}
    end
  end

  @doc """
  The period of the same length immediately before this one.

  What the trend indicator compares against: seven days measured against
  the seven before them, so a Monday is always weighed against a Monday.
  """
  @spec previous(t()) :: t()
  def previous(%__MODULE__{} = period) do
    to = DateTime.add(period.from, -1, :second)
    from = DateTime.add(period.from, -period.days * 24 * 3_600, :second)

    %__MODULE__{
      from: from,
      to: to,
      label: "previous #{period.days} days",
      days: period.days
    }
  end

  @doc "Every date in the period, oldest first — the x-axis of the trend."
  @spec dates(t()) :: [Date.t()]
  def dates(%__MODULE__{} = period) do
    first = DateTime.to_date(period.from)
    last = DateTime.to_date(period.to)

    Date.range(first, last) |> Enum.to_list()
  end

  @doc "Whether a timestamp falls inside the period."
  @spec covers?(t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{from: from, to: to}, timestamp) do
    DateTime.compare(timestamp, from) != :lt and DateTime.compare(timestamp, to) != :gt
  end

  @doc """
  A filename-safe stamp for this period, e.g. `2026-09-05_2026-09-11`.
  """
  @spec slug(t()) :: String.t()
  def slug(%__MODULE__{} = period) do
    "#{DateTime.to_date(period.from)}_#{DateTime.to_date(period.to)}"
  end

  @doc "Human dates for the report's cover, e.g. `5 Sep 2026 – 11 Sep 2026`."
  @spec human_range(t()) :: String.t()
  def human_range(%__MODULE__{} = period) do
    "#{period.from |> DateTime.to_date() |> format()} – " <>
      "#{period.to |> DateTime.to_date() |> format()}"
  end

  defp start_of_day(date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  # The last microsecond of the day, so a mention at 23:59:59 is inside
  # the period it belongs to rather than falling through the gap.
  defp end_of_day(date), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")

  defp format(date), do: Calendar.strftime(date, "%-d %b %Y")
end
