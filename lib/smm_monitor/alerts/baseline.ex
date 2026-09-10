defmodule SmmMonitor.Alerts.Baseline do
  @moduledoc """
  What a normal hour looks like for a client.

  Volume alerting compares now against normal, and "normal" for social
  mentions is not a flat number: brands are busy in the working day and
  quiet at 3am, busy on weekdays and quiet at weekends. A flat average
  over a week says a Tuesday lunchtime and a Sunday night should look
  alike, so it alerts every weekday morning and misses a genuine weekend
  storm.

  So the baseline is **the same hour of the day over the last N days**:
  9am today is compared against the last seven 9ams. It is a crude
  seasonal model and deliberately so — a real one needs more history
  than a monitoring tool has on its first week.

  ## Reading a short history honestly

  A client added yesterday has one day of history, not seven. Averaging
  over seven days regardless would divide by days that never happened
  and make every hour look like a spike. So the average is over the days
  actually observed, and `days_observed` comes back with it so the caller
  can refuse to alert until there is enough to be worth comparing.

  Pure functions over a list of timestamps: no database, no clock beyond
  what it is handed.
  """

  @typedoc """
  What the baseline is worth.

    * `:average` — mentions in an average same-hour window
    * `:days_observed` — how many of the requested days had any history
    * `:samples` — the per-day counts, oldest first, for the alert body
  """
  @type t :: %{
          average: float(),
          days_observed: non_neg_integer(),
          samples: [non_neg_integer()]
        }

  @doc """
  Averages the count of `timestamps` falling in the same clock hour on
  each of the `days` days before `now`.

  `now` itself is excluded: the current window is what we are comparing
  *against* this, and including it would let a spike raise its own
  baseline.

      iex> alias SmmMonitor.Alerts.Baseline
      iex> now = ~U[2026-09-12 09:30:00Z]
      iex> yesterday = ~U[2026-09-11 09:15:00Z]
      iex> two_days = ~U[2026-09-10 09:45:00Z]
      iex> baseline = Baseline.same_hour([yesterday, yesterday, two_days], now, 7)
      iex> {baseline.average, baseline.days_observed}
      {1.5, 2}
  """
  @spec same_hour([DateTime.t()], DateTime.t(), pos_integer()) :: t()
  def same_hour(timestamps, now, days) when days > 0 do
    windows = Enum.map(1..days, &day_window(now, &1))

    samples =
      windows
      |> Enum.map(fn {from, to} -> Enum.count(timestamps, &within?(&1, from, to)) end)
      |> Enum.reverse()

    # A day with no mentions at all is not evidence of a quiet hour, it
    # is evidence of no history: counting it as a zero would drag the
    # baseline down and turn an ordinary hour into a spike. Days before
    # the client existed look identical to quiet ones from here, so the
    # caller is told how many days actually had something in them.
    observed = Enum.count(samples, &(&1 > 0))

    %{
      average: average(samples, observed),
      days_observed: observed,
      samples: samples
    }
  end

  @doc """
  How far above the baseline an observation is.

  `:infinity` when the baseline is zero and something was seen — a
  client that normally has no mentions at this hour suddenly having
  twenty is the clearest signal there is, even though the ratio is
  undefined.

      iex> alias SmmMonitor.Alerts.Baseline
      iex> Baseline.ratio(12, 3.0)
      4.0
      iex> Baseline.ratio(5, 0.0)
      :infinity
      iex> Baseline.ratio(0, 4.0)
      0.0
  """
  @spec ratio(non_neg_integer(), float()) :: float() | :infinity
  def ratio(0, _baseline), do: 0.0
  def ratio(_observed, baseline) when baseline <= 0, do: :infinity
  def ratio(observed, baseline), do: observed / baseline

  # --- internals ------------------------------------------------------------

  # The same clock hour, `days_ago` days back: 09:00:00 to 09:59:59.999
  # regardless of what minute it is now, so the comparison is hour to
  # hour rather than a rolling window against a fixed one.
  defp day_window(now, days_ago) do
    from =
      now
      |> DateTime.add(-days_ago * 24 * 3_600, :second)
      |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 6}})

    {from, DateTime.add(from, 3_600, :second)}
  end

  defp within?(timestamp, from, to) do
    DateTime.compare(timestamp, from) != :lt and DateTime.compare(timestamp, to) == :lt
  end

  defp average(_samples, 0), do: 0.0

  defp average(samples, observed) do
    samples |> Enum.sum() |> Kernel./(observed) |> Float.round(2)
  end
end
