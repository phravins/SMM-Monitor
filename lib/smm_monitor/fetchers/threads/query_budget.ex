defmodule SmmMonitor.Fetchers.Threads.QueryBudget do
  @moduledoc """
  Counts Threads keyword searches against a rolling 24-hour budget.

  Meta allows **2,200 keyword-search queries per rolling 24 hours, per
  Threads user**, shared by every app that user has authorised. Unlike
  YouTube's quota there is no reset at midnight: a query made at 14:05
  frees up again at 14:05 tomorrow. So this keeps the time of every query
  in the window and counts them, rather than keeping a daily total.

  The budget defaults to 2,000, below Meta's ceiling, leaving room for
  other apps on the same account. Meta doesn't count a query that returns
  nothing; this counts every request, so it errs on the side of stopping
  early. Meta reports no running total, so this is our own estimate: it
  can't see other apps' queries, and it starts from zero when the app
  restarts. Meta's own limit still stands behind it.

  A struct plus functions, living in the Threads worker's state.
  """

  @window_ms :timer.hours(24)
  @default_budget 2_000

  # Meta's ceiling. A budget above it would only ever be stopped by Meta.
  @max_budget 2_200

  defstruct budget: @default_budget, spent: [], exhausted_logged: false

  @type t :: %__MODULE__{
          budget: pos_integer(),
          spent: [integer()],
          exhausted_logged: boolean()
        }

  @doc "Meta's ceiling: 2,200 queries per rolling 24 hours."
  @spec max_budget() :: pos_integer()
  def max_budget, do: @max_budget

  @doc "The default budget."
  @spec default_budget() :: pos_integer()
  def default_budget, do: @default_budget

  @doc """
  A fresh tracker. The budget is clamped to `1..2200`.

      iex> alias SmmMonitor.Fetchers.Threads.QueryBudget
      iex> QueryBudget.new(5_000).budget
      2200
  """
  @spec new(integer() | nil) :: t()
  def new(budget \\ @default_budget)
  def new(nil), do: new(@default_budget)

  def new(budget) when is_integer(budget),
    do: %__MODULE__{budget: budget |> max(1) |> min(@max_budget)}

  @doc "Queries left in the window ending at `now_ms`."
  @spec remaining(t(), integer()) :: non_neg_integer()
  def remaining(%__MODULE__{} = budget, now_ms) do
    max(budget.budget - length(in_window(budget.spent, now_ms)), 0)
  end

  @doc "Records one query made at `now_ms`."
  @spec spend(t(), integer()) :: t()
  def spend(%__MODULE__{} = budget, now_ms) do
    %{budget | spent: [now_ms | in_window(budget.spent, now_ms)], exhausted_logged: false}
  end

  @doc """
  How long until a query frees up: 0 while any remain, otherwise the time
  until the oldest one in the window is 24 hours old.

      iex> alias SmmMonitor.Fetchers.Threads.QueryBudget
      iex> budget = QueryBudget.new(2) |> QueryBudget.spend(0) |> QueryBudget.spend(1_000)
      iex> QueryBudget.wait_ms(budget, 60_000)
      86_340_000
      iex> QueryBudget.wait_ms(budget, 86_399_500)
      1_000
      iex> QueryBudget.wait_ms(budget, 86_400_000)
      0
  """
  @spec wait_ms(t(), integer()) :: non_neg_integer()
  def wait_ms(%__MODULE__{} = budget, now_ms) do
    case remaining(budget, now_ms) do
      0 ->
        oldest = budget.spent |> in_window(now_ms) |> List.last()
        max(oldest + @window_ms - now_ms, 1_000)

      _some ->
        0
    end
  end

  @doc """
  Marks the exhaustion as logged. Returns whether it already was, so the
  "budget spent" warning appears once per exhaustion, not once per client.
  """
  @spec mark_exhausted_logged(t()) :: {boolean(), t()}
  def mark_exhausted_logged(%__MODULE__{exhausted_logged: logged?} = budget),
    do: {logged?, %{budget | exhausted_logged: true}}

  @doc "A short summary for logs."
  @spec summary(t(), integer()) :: String.t()
  def summary(%__MODULE__{} = budget, now_ms) do
    used = length(in_window(budget.spent, now_ms))
    "#{used} of #{budget.budget} searches used in the last 24 hours"
  end

  # Newest first, so everything after the first stale entry is stale too.
  defp in_window(spent, now_ms) do
    Enum.take_while(spent, &(&1 > now_ms - @window_ms))
  end
end
