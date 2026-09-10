defmodule SmmMonitor.Fetchers.Twitter.PostBudgetTest do
  @moduledoc """
  The monthly post cap: the limit that ends a month early, counted
  locally because no response header reports it.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SmmMonitor.Fetchers.Twitter.PostBudget

  doctest PostBudget

  @mid_month ~U[2026-09-10 12:00:00Z]

  describe "check/3" do
    test "allows a search while the budget covers its worst case" do
      # Checked before spending, using the page size, so a search can't
      # overshoot the cap by up to a page.
      assert PostBudget.check(PostBudget.new(1_000, 1, @mid_month), 100, @mid_month) == :ok
    end

    test "stands down when the next search could exceed the budget" do
      budget = PostBudget.spend(PostBudget.new(100, 1, @mid_month), 95)

      assert {:exhausted, wait_ms} = PostBudget.check(budget, 25, @mid_month)
      assert wait_ms > 0
    end

    test "the backoff runs to the next cycle boundary" do
      budget = PostBudget.spend(PostBudget.new(10, 1, @mid_month), 10)

      {:exhausted, wait_ms} = PostBudget.check(budget, 25, @mid_month)

      # 2026-09-10 12:00 → 2026-10-01 00:00 is 20 days and 12 hours.
      assert_in_delta wait_ms, :timer.hours(20 * 24 + 12), :timer.minutes(1)
    end
  end

  describe "spend/2" do
    test "counts posts returned, not the page size requested" do
      # The cap charges for posts delivered: a search matching three
      # tweets costs three, however large a page we asked for.
      budget = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 3)

      assert budget.used == 3
      assert budget.calls == 1
    end

    test "accumulates across searches" do
      budget =
        Enum.reduce(1..4, PostBudget.new(1_000, 1, @mid_month), fn _i, acc ->
          PostBudget.spend(acc, 25)
        end)

      assert budget.used == 100
      assert budget.calls == 4
      assert PostBudget.remaining(budget) == 900
    end

    test "a search that matched nothing costs nothing" do
      budget = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 0)

      assert budget.used == 0
      assert budget.calls == 1
    end
  end

  describe "rollover/2" do
    test "resets the count when the cycle turns" do
      budget = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 900)

      rolled =
        capture_log_and_return(fn -> PostBudget.rollover(budget, ~U[2026-10-01 00:05:00Z]) end)

      assert rolled.used == 0
      assert rolled.calls == 0
    end

    test "leaves the count alone inside the same cycle" do
      budget = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 900)

      assert PostBudget.rollover(budget, ~U[2026-09-28 23:00:00Z]).used == 900
    end

    test "lets polling resume after standing down" do
      spent = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 1_000)
      assert {:exhausted, _ms} = PostBudget.check(spent, 25, @mid_month)

      rolled =
        capture_log_and_return(fn -> PostBudget.rollover(spent, ~U[2026-10-02 00:00:00Z]) end)

      assert PostBudget.check(rolled, 25, ~U[2026-10-02 00:00:00Z]) == :ok
    end

    test "clears the logged flag, so a new cycle can report exhaustion again" do
      {_logged?, budget} =
        PostBudget.new(10, 1, @mid_month)
        |> PostBudget.spend(10)
        |> PostBudget.mark_exhausted_logged()

      rolled =
        capture_log_and_return(fn -> PostBudget.rollover(budget, ~U[2026-10-02 00:00:00Z]) end)

      refute rolled.exhausted_logged
    end
  end

  describe "billing cycles that don't start on the 1st" do
    test "a cycle starting on the 12th isn't a calendar month" do
      # Mid-September, on a cycle that turns on the 12th, belongs to the
      # cycle that began in August.
      budget = PostBudget.new(1_000, 12, ~U[2026-09-10 12:00:00Z])

      assert budget.cycle_start == ~D[2026-08-12]
    end

    test "rolls over on the cycle day, not the month boundary" do
      # This cycle began on 2026-09-12 and runs to 2026-10-12.
      budget = PostBudget.spend(PostBudget.new(1_000, 12, ~U[2026-09-15 12:00:00Z]), 500)

      assert budget.cycle_start == ~D[2026-09-12]
      # The 1st of October is inside it, not the start of a new one.
      assert PostBudget.rollover(budget, ~U[2026-10-01 00:00:00Z]).used == 500

      rolled =
        capture_log_and_return(fn -> PostBudget.rollover(budget, ~U[2026-10-12 00:30:00Z]) end)

      assert rolled.used == 0
    end

    test "a cycle day of 31 survives a 30-day month" do
      # There is no 31st of September; the cycle has to land on the 30th.
      budget = PostBudget.new(1_000, 31, ~U[2026-09-15 12:00:00Z])

      assert budget.cycle_start == ~D[2026-08-31]
      assert PostBudget.ms_until_reset(budget, ~U[2026-09-15 12:00:00Z]) > 0
    end

    test "a cycle day of 31 survives February" do
      budget = PostBudget.new(1_000, 31, ~U[2026-02-15 12:00:00Z])

      assert budget.cycle_start == ~D[2026-01-31]
      # 2026 is not a leap year, so the next boundary is the 28th.
      assert_in_delta PostBudget.ms_until_reset(budget, ~U[2026-02-15 12:00:00Z]),
                      :timer.hours(12 * 24 + 12),
                      :timer.minutes(1)
    end
  end

  describe "page_size/3" do
    test "asks for the full page while the budget is comfortable" do
      assert {:ok, 25} = PostBudget.page_size(PostBudget.new(1_000, 1, @mid_month), 25, 10)
    end

    test "trims the page to what is left, rather than standing down early" do
      # 12 posts of budget left and a 25-post page: buy 12, don't waste
      # the rest of the cycle's allowance.
      budget = PostBudget.spend(PostBudget.new(100, 1, @mid_month), 88)

      assert {:ok, 12} = PostBudget.page_size(budget, 25, 10)
    end

    test "gives up only when the API's smallest page won't fit" do
      budget = PostBudget.spend(PostBudget.new(100, 1, @mid_month), 95)

      assert PostBudget.page_size(budget, 25, 10) == :none
    end

    test "a budget smaller than one page still allows a search" do
      # Otherwise a low budget would never permit a single request.
      assert {:ok, 10} = PostBudget.page_size(PostBudget.new(10, 1, @mid_month), 25, 10)
    end
  end

  describe "mark_exhausted_logged/1" do
    test "reports standing down once per cycle, not once per poll" do
      budget = PostBudget.new(10, 1, @mid_month)

      assert {false, budget} = PostBudget.mark_exhausted_logged(budget)
      assert {true, _budget} = PostBudget.mark_exhausted_logged(budget)
    end
  end

  describe "summary/1" do
    test "says what has been used and what is left" do
      budget = PostBudget.spend(PostBudget.new(1_000, 1, @mid_month), 250)

      assert PostBudget.summary(budget) == "250/1000 posts used this cycle (750 left)"
    end
  end

  # The rollover logs at :info when a cycle turns; that is deliberate, and
  # not what these tests are asserting.
  defp capture_log_and_return(fun) do
    {result, _log} = with_log(fun)
    result
  end
end
