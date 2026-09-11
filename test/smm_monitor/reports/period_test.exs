defmodule SmmMonitor.Reports.PeriodTest do
  @moduledoc """
  The stretch of time a report covers — and the one before it, which is
  what makes every number in the report mean something.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Reports.Period

  doctest Period

  describe "last_days/2" do
    test "covers whole days, ending today" do
      period = Period.last_days(7, ~D[2026-09-11])

      assert DateTime.to_date(period.from) == ~D[2026-09-05]
      assert DateTime.to_date(period.to) == ~D[2026-09-11]
      assert period.days == 7
    end

    test "starts at midnight and ends at the last moment of the day" do
      # A client asking for "last 7 days" means seven calendar days, not
      # 168 hours ending at 14:32 — and a mention at 23:59 belongs to the
      # period it was posted in.
      period = Period.last_days(1, ~D[2026-09-11])

      assert period.from == ~U[2026-09-11 00:00:00.000000Z]
      assert Period.covers?(period, ~U[2026-09-11 23:59:59Z])
      refute Period.covers?(period, ~U[2026-09-12 00:00:00Z])
    end

    test "one day is a period, not an error" do
      assert Period.last_days(1, ~D[2026-09-11]).days == 1
    end
  end

  describe "between/2" do
    test "is inclusive at both ends" do
      {:ok, period} = Period.between(~D[2026-09-01], ~D[2026-09-07])

      assert period.days == 7
      assert Period.covers?(period, ~U[2026-09-01 00:00:01Z])
      assert Period.covers?(period, ~U[2026-09-07 23:00:00Z])
    end

    test "a single day is seven days minus six" do
      {:ok, period} = Period.between(~D[2026-09-07], ~D[2026-09-07])

      assert period.days == 1
    end

    test "a backwards range is refused rather than silently swapped" do
      # Swapping them would produce a report for a period nobody asked
      # for, which is worse than saying no.
      assert {:error, :inverted_range} = Period.between(~D[2026-09-07], ~D[2026-09-01])
    end
  end

  describe "previous/1" do
    test "is the same length, immediately before" do
      period = Period.last_days(7, ~D[2026-09-11])
      previous = Period.previous(period)

      assert previous.days == 7
      assert DateTime.to_date(previous.to) == ~D[2026-09-04]
      assert DateTime.to_date(previous.from) == ~D[2026-08-29]
    end

    test "does not overlap the period it precedes" do
      # An overlap would let the current period's mentions count towards
      # the baseline they are being compared against.
      period = Period.last_days(7, ~D[2026-09-11])
      previous = Period.previous(period)

      assert DateTime.compare(previous.to, period.from) == :lt
    end

    test "leaves no gap either" do
      period = Period.last_days(7, ~D[2026-09-11])
      previous = Period.previous(period)

      assert DateTime.diff(period.from, previous.to, :second) == 1
    end
  end

  describe "dates/1" do
    test "is every day in the period, oldest first" do
      dates = Period.dates(Period.last_days(3, ~D[2026-09-11]))

      assert dates == [~D[2026-09-09], ~D[2026-09-10], ~D[2026-09-11]]
    end

    test "has one entry per day, so a silent day is a zero not a gap" do
      assert length(Period.dates(Period.last_days(30, ~D[2026-09-11]))) == 30
    end
  end

  describe "labels" do
    test "the slug sorts chronologically in a directory listing" do
      period = Period.last_days(7, ~D[2026-09-11])

      assert Period.slug(period) == "2026-09-05_2026-09-11"
    end

    test "the human range is what goes on the cover" do
      period = Period.last_days(7, ~D[2026-09-11])

      assert Period.human_range(period) == "5 Sep 2026 – 11 Sep 2026"
    end
  end
end
