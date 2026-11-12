defmodule SmmMonitor.Fetchers.Threads.QueryBudgetTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.Threads.{QueryBudget, Sources}

  doctest QueryBudget
  doctest Sources

  @day :timer.hours(24)

  test "starts at the default budget" do
    assert QueryBudget.remaining(QueryBudget.new(), 0) == 2_000
    assert QueryBudget.new(nil).budget == 2_000
  end

  test "is clamped to Meta's ceiling and to at least one" do
    assert QueryBudget.new(10_000).budget == QueryBudget.max_budget()
    assert QueryBudget.new(0).budget == 1
    assert QueryBudget.new(-5).budget == 1
  end

  test "each query uses one" do
    budget = QueryBudget.new(3) |> QueryBudget.spend(0) |> QueryBudget.spend(10)

    assert QueryBudget.remaining(budget, 20) == 1
    assert QueryBudget.wait_ms(budget, 20) == 0
  end

  test "a query frees up 24 hours after it was made, not at midnight" do
    budget = QueryBudget.new(2) |> QueryBudget.spend(1_000) |> QueryBudget.spend(5_000)

    assert QueryBudget.remaining(budget, @day) == 0
    assert QueryBudget.remaining(budget, @day + 1_000) == 1
    assert QueryBudget.remaining(budget, @day + 5_000) == 2
  end

  test "the wait is until the oldest query in the window ages out" do
    budget = QueryBudget.new(2) |> QueryBudget.spend(1_000) |> QueryBudget.spend(5_000)

    assert QueryBudget.wait_ms(budget, 10_000) == @day + 1_000 - 10_000
  end

  test "old entries are dropped as new ones are recorded" do
    budget = QueryBudget.new(5) |> QueryBudget.spend(0) |> QueryBudget.spend(@day + 1)

    assert budget.spent == [@day + 1]
  end

  test "the exhaustion warning is marked once, and reset by the next query" do
    budget = QueryBudget.new(1)

    assert {false, budget} = QueryBudget.mark_exhausted_logged(budget)
    assert {true, budget} = QueryBudget.mark_exhausted_logged(budget)

    budget = QueryBudget.spend(budget, 0)
    assert {false, _budget} = QueryBudget.mark_exhausted_logged(budget)
  end

  test "summarises usage" do
    budget = QueryBudget.new(10) |> QueryBudget.spend(0) |> QueryBudget.spend(1)

    assert QueryBudget.summary(budget, 2) == "2 of 10 searches used in the last 24 hours"
  end
end
