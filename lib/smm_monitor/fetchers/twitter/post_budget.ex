defmodule SmmMonitor.Fetchers.Twitter.PostBudget do
  @moduledoc """
  Tracks the monthly **post cap** — X's other, slower limit.

  Recent search is bounded twice, and the two behave nothing alike:

    * a per-15-minute request window, reported in response headers and
      handled by `SmmMonitor.Fetchers.Twitter.RateLimit`;
    * a **monthly cap on Posts returned**, counted per Project across
      every app in it, and *not* reported in any response header.

  The second is the one that ends a month early. Nothing in a response
  says how close it is, so — exactly like YouTube's daily quota — we keep
  our own count and stand down at a budget below the real ceiling.

  ## The number is deliberately conservative

  The cap depends on the access tier and X has repriced and renamed the
  tiers more than once. Rather than compile in a number that may be wrong
  in six months, the default is a low 10,000 posts a month and
  `SMM_TWITTER_MONTHLY_POST_BUDGET` raises it to whatever the plan
  actually allows. Standing down early costs coverage a raised number
  fixes in one restart; overrunning the cap costs the month.

  Because the count is ours alone it cannot see other apps in the same
  Project — which is the reason for a budget rather than a ceiling. The
  true figure is at `GET /2/usage/tweets`; the README says how to read it.

  ## The reset boundary

  The cap resets on the Project's billing cycle, which is not necessarily
  the 1st. `:cycle_day` says which day of the month it rolls over, so a
  cycle starting on the 12th isn't counted against a calendar month.

  A struct plus functions; it lives in the worker's state.
  """

  require Logger

  @default_budget 10_000
  @default_cycle_day 1

  defstruct used: 0,
            calls: 0,
            budget: @default_budget,
            cycle_day: @default_cycle_day,
            cycle_start: nil,
            exhausted_logged: false

  @type t :: %__MODULE__{
          used: non_neg_integer(),
          calls: non_neg_integer(),
          budget: pos_integer(),
          cycle_day: pos_integer(),
          cycle_start: Date.t() | nil,
          exhausted_logged: boolean()
        }

  @doc "A fresh tracker for the current billing cycle."
  @spec new(pos_integer(), pos_integer(), DateTime.t()) :: t()
  def new(budget \\ @default_budget, cycle_day \\ @default_cycle_day, now \\ DateTime.utc_now()) do
    %__MODULE__{
      budget: budget,
      cycle_day: cycle_day,
      cycle_start: cycle_start(now, cycle_day)
    }
  end

  @doc """
  Rolls the counter over if the billing cycle has turned.

  Called before every check, so a worker that stood down last month starts
  spending again on its first poll after the boundary.
  """
  @spec rollover(t(), DateTime.t()) :: t()
  def rollover(%__MODULE__{} = budget, now \\ DateTime.utc_now()) do
    current = cycle_start(now, budget.cycle_day)

    if budget.cycle_start == current do
      budget
    else
      if budget.used > 0 do
        Logger.info(
          "twitter: post cap cycle rolled over, #{budget.used} post(s) consumed last cycle " <>
            "across #{budget.calls} search(es); budget available again"
        )
      end

      %{budget | used: 0, calls: 0, cycle_start: current, exhausted_logged: false}
    end
  end

  @doc """
  Whether there is budget to run another search.

  `max_results` is what the next search could return at worst, so the
  decision is made *before* spending rather than after overshooting.
  Returns `:ok` or `{:exhausted, ms_until_reset}`.
  """
  @spec check(t(), pos_integer(), DateTime.t()) :: :ok | {:exhausted, pos_integer()}
  def check(%__MODULE__{} = budget, max_results, now \\ DateTime.utc_now()) do
    if budget.used + max_results <= budget.budget do
      :ok
    else
      {:exhausted, ms_until_reset(budget, now)}
    end
  end

  @doc """
  The page size to ask for: `requested`, trimmed to what is left.

  Without this, a budget with 12 posts left and a 25-post page size would
  stand the platform down holding unspent budget — and a budget set lower
  than one page would never allow a single search. Returns `:none` when
  even the API's smallest page (`min_page`) won't fit, which is the point
  at which standing down is the honest answer.
  """
  @spec page_size(t(), pos_integer(), pos_integer()) :: {:ok, pos_integer()} | :none
  def page_size(%__MODULE__{} = budget, requested, min_page) do
    affordable = min(requested, remaining(budget))

    if affordable >= min_page, do: {:ok, affordable}, else: :none
  end

  @doc """
  Records the posts a search actually returned.

  Counted from the response rather than from `max_results`, because the
  cap counts Posts delivered — a search that matched three tweets costs
  three, not the page size we asked for.
  """
  @spec spend(t(), non_neg_integer()) :: t()
  def spend(%__MODULE__{} = budget, posts) do
    %{budget | used: budget.used + posts, calls: budget.calls + 1}
  end

  @doc """
  Marks exhaustion as logged, so standing down is reported once a cycle
  rather than on every poll. Returns `{already_logged?, budget}`.
  """
  @spec mark_exhausted_logged(t()) :: {boolean(), t()}
  def mark_exhausted_logged(%__MODULE__{exhausted_logged: true} = budget), do: {true, budget}

  def mark_exhausted_logged(%__MODULE__{} = budget),
    do: {false, %{budget | exhausted_logged: true}}

  @doc "Posts still available this cycle."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = budget), do: max(budget.budget - budget.used, 0)

  @doc "A short summary for logs and the dashboard's status line."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = budget) do
    "#{budget.used}/#{budget.budget} posts used this cycle (#{remaining(budget)} left)"
  end

  @doc """
  Milliseconds until the next cycle boundary.

  Used as the backoff once the budget is spent: there is nothing to be
  gained by asking again before then.
  """
  @spec ms_until_reset(t(), DateTime.t()) :: pos_integer()
  def ms_until_reset(%__MODULE__{cycle_day: cycle_day}, now \\ DateTime.utc_now()) do
    next = next_cycle_start(now, cycle_day)
    seconds = DateTime.diff(DateTime.new!(next, ~T[00:00:00], "Etc/UTC"), now, :second)
    max(seconds, 1) * 1_000
  end

  @doc """
  The date the cycle containing `now` began.

      iex> alias SmmMonitor.Fetchers.Twitter.PostBudget
      iex> PostBudget.cycle_start(~U[2026-09-10 12:00:00Z], 1)
      ~D[2026-09-01]
      iex> PostBudget.cycle_start(~U[2026-09-10 12:00:00Z], 12)
      ~D[2026-08-12]
  """
  @spec cycle_start(DateTime.t(), pos_integer()) :: Date.t()
  def cycle_start(now, cycle_day) do
    today = DateTime.to_date(now)
    day = clamp_day(today, cycle_day)

    if today.day >= day do
      %{today | day: day}
    else
      previous = shift_months(today, -1)
      %{previous | day: clamp_day(previous, cycle_day)}
    end
  end

  # --- internals ------------------------------------------------------------

  defp next_cycle_start(now, cycle_day) do
    now
    |> cycle_start(cycle_day)
    |> shift_months(1)
    |> then(fn date -> %{date | day: clamp_day(date, cycle_day)} end)
  end

  # A cycle day of 31 has to mean "the 30th" in a 30-day month, and the
  # 28th or 29th in February, or the date wouldn't exist.
  defp clamp_day(date, cycle_day) do
    min(cycle_day, Date.days_in_month(date))
  end

  defp shift_months(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    # Day 1 always exists, so this is safe before the day is clamped.
    Date.new!(year, month, 1)
  end
end
