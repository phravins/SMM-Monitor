defmodule SmmMonitor.Fetchers.YouTube.Quota do
  @moduledoc """
  Tracks YouTube Data API quota against a conservative daily budget.

  The free tier allows 10,000 units a day and a `search.list` call costs
  100 of them — so 100 searches a day, total. That is a small enough
  number that spending it accidentally is easy, and the consequence is
  every YouTube call failing until the quota resets. So we keep our own
  count and stop at a budget below the real ceiling (8,000 by default),
  leaving headroom for anything else using the same key.

  Unlike Reddit's rate limit, this can't be read back from response
  headers — Google doesn't report remaining quota — so the count here is
  ours alone. It is therefore an estimate: it can't see usage from another
  process sharing the key, which is exactly why the budget leaves 20% in
  reserve.

  ## The reset boundary

  YouTube's quota resets at **midnight Pacific Time**, not UTC. Rather
  than take on a timezone database for one boundary, we shift UTC by a
  fixed -8 hours. During daylight saving the true boundary is an hour
  earlier than we think, so for one hour a day we may believe we have a
  fresh budget slightly before we do — harmless against a budget that
  already holds 2,000 units back.

  Like Reddit's trackers, this is a struct plus functions with no process
  of its own; it lives in the YouTube worker's state.
  """

  require Logger

  # What each call type costs. Only search is used today; listed so the
  # cost is stated once rather than sprinkled through the fetcher.
  @search_cost 100

  @default_budget 8_000

  # YouTube's quota day is Pacific. See the moduledoc on the approximation.
  @pacific_offset_s -8 * 3_600

  defstruct used: 0,
            day: nil,
            budget: @default_budget,
            calls: 0,
            exhausted_logged: false

  @type t :: %__MODULE__{
          used: non_neg_integer(),
          day: Date.t() | nil,
          budget: pos_integer(),
          calls: non_neg_integer(),
          exhausted_logged: boolean()
        }

  @doc "Cost in quota units of one `search.list` call."
  @spec search_cost() :: pos_integer()
  def search_cost, do: @search_cost

  @doc "A fresh tracker for the current quota day."
  @spec new(pos_integer(), DateTime.t()) :: t()
  def new(budget \\ @default_budget, now \\ DateTime.utc_now()) do
    %__MODULE__{budget: budget, day: quota_day(now)}
  end

  @doc """
  Rolls the counter over if the quota day has changed.

  Called before every check, so a worker that stood down yesterday starts
  spending again on its first poll after the boundary.
  """
  @spec rollover(t(), DateTime.t()) :: t()
  def rollover(%__MODULE__{} = quota, now \\ DateTime.utc_now()) do
    today = quota_day(now)

    if quota.day == today do
      quota
    else
      if quota.used > 0 do
        Logger.info(
          "youtube: quota day rolled over, #{quota.used} units used yesterday across " <>
            "#{quota.calls} call(s); budget available again"
        )
      end

      %{quota | used: 0, calls: 0, day: today, exhausted_logged: false}
    end
  end

  @doc """
  Whether there is budget for a call costing `cost` units.

  Returns `:ok`, or `{:exhausted, ms_until_reset}` — the delay the worker
  should wait, which is however long is left of the quota day.
  """
  @spec check(t(), pos_integer(), DateTime.t()) :: :ok | {:exhausted, pos_integer()}
  def check(%__MODULE__{} = quota, cost \\ @search_cost, now \\ DateTime.utc_now()) do
    if quota.used + cost <= quota.budget do
      :ok
    else
      {:exhausted, ms_until_reset(now)}
    end
  end

  @doc "Records that a call costing `cost` units was made."
  @spec spend(t(), pos_integer()) :: t()
  def spend(%__MODULE__{} = quota, cost \\ @search_cost) do
    %{quota | used: quota.used + cost, calls: quota.calls + 1}
  end

  @doc """
  Marks the exhaustion as logged, so standing down is reported once a day
  rather than on every poll.

  Returns `{already_logged?, quota}`.
  """
  @spec mark_exhausted_logged(t()) :: {boolean(), t()}
  def mark_exhausted_logged(%__MODULE__{exhausted_logged: true} = quota), do: {true, quota}

  def mark_exhausted_logged(%__MODULE__{} = quota),
    do: {false, %{quota | exhausted_logged: true}}

  @doc "Units still available today."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = quota), do: max(quota.budget - quota.used, 0)

  @doc "How many further calls of `cost` units fit in the budget."
  @spec calls_remaining(t(), pos_integer()) :: non_neg_integer()
  def calls_remaining(%__MODULE__{} = quota, cost \\ @search_cost),
    do: div(remaining(quota), cost)

  @doc "A short summary for logs and the dashboard's status line."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = quota) do
    "#{quota.used}/#{quota.budget} units used today (#{calls_remaining(quota)} searches left)"
  end

  @doc """
  Milliseconds until the next quota reset.

  Used as the backoff when the budget is spent: there is no point polling
  again until the boundary.
  """
  @spec ms_until_reset(DateTime.t()) :: pos_integer()
  def ms_until_reset(now \\ DateTime.utc_now()) do
    seconds_into_day =
      now
      |> shift_to_pacific()
      |> then(fn pacific -> pacific.hour * 3_600 + pacific.minute * 60 + pacific.second end)

    max(86_400 - seconds_into_day, 1) * 1_000
  end

  @doc """
  The quota day `now` falls in, as a Pacific-time date.

      iex> alias SmmMonitor.Fetchers.YouTube.Quota
      iex> Quota.quota_day(~U[2026-03-10 03:00:00Z])
      ~D[2026-03-09]
      iex> Quota.quota_day(~U[2026-03-10 20:00:00Z])
      ~D[2026-03-10]
  """
  @spec quota_day(DateTime.t()) :: Date.t()
  def quota_day(now), do: now |> shift_to_pacific() |> DateTime.to_date()

  defp shift_to_pacific(now), do: DateTime.add(now, @pacific_offset_s, :second)
end
