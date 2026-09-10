defmodule SmmMonitor.Alerts.DetectorTest do
  @moduledoc """
  The judgement, tested by handing it numbers rather than by waiting for
  a real spike. Each of the three guards gets its own cases, because each
  exists to suppress a different false alarm.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Detector

  doctest Detector

  @window :timer.hours(1)
  @week :timer.hours(24) * 7

  describe "the ratio guard" do
    test "alerts when negatives far exceed the baseline" do
      assert {:alert, alert} = evaluate(observed: 12, baseline: 2.0)

      assert alert.kind == :negative_spike
      assert alert.observed == 12
      assert alert.ratio == 6.0
    end

    test "stays quiet when negatives are merely elevated" do
      # 2x normal is a busy afternoon, not an emergency.
      assert {:ok, :below_threshold} = evaluate(observed: 12, baseline: 6.0)
    end

    test "alerts exactly at the threshold" do
      assert {:alert, _alert} = evaluate(observed: 12, baseline: 4.0)
    end

    test "stays quiet just under it" do
      assert {:ok, :below_threshold} = evaluate(observed: 12, baseline: 4.1)
    end

    test "treats a zero baseline with observations as a spike" do
      # A brand that has never had a negative mention getting several is
      # a real signal, even though the ratio is undefined.
      assert {:alert, alert} = evaluate(observed: 8, baseline: 0)
      assert alert.ratio == :infinity
      assert alert.severity == :critical
    end
  end

  describe "the floor guard" do
    test "ignores a handful of negatives however large the multiple" do
      # 4 against a baseline of 0.1 is 40x, and still only four posts.
      assert {:ok, :below_threshold} = evaluate(observed: 4, baseline: 0.1)
    end

    test "alerts once the floor is cleared" do
      assert {:alert, _alert} = evaluate(observed: 5, baseline: 0.1)
    end

    test "the floor is configurable" do
      assert {:alert, _alert} = evaluate([observed: 3, baseline: 0.1], floor: 3)
    end
  end

  describe "the warm-up guard" do
    test "stays quiet until there is enough history to know what normal is" do
      # Every fresh install's first hour would otherwise look like a crisis.
      assert {:ok, :warming_up} =
               evaluate([observed: 50, baseline: 0.1], history_ms: :timer.hours(2))
    end

    test "stays quiet when there is no baseline at all" do
      assert {:ok, :warming_up} = evaluate(observed: 50, baseline: nil)
    end

    test "alerts once past warm-up" do
      assert {:alert, _alert} =
               evaluate([observed: 50, baseline: 1.0], history_ms: :timer.hours(25))
    end
  end

  describe "severity" do
    test "is a warning for a moderate spike" do
      assert {:alert, %{severity: :warning}} = evaluate(observed: 12, baseline: 3.0)
    end

    test "is critical past the critical ratio" do
      assert {:alert, %{severity: :critical}} = evaluate(observed: 12, baseline: 1.0)
    end
  end

  describe "the alert it produces" do
    test "carries the evidence, not just a verdict" do
      assert {:alert, alert} = evaluate(observed: 20, baseline: 2.0, total: 35)

      assert alert.platform == :reddit
      assert alert.observed == 20
      assert alert.total == 35
      assert alert.baseline == 2.0
      assert alert.window_ms == @window
      assert %DateTime{} = alert.at
    end

    test "uses the injected clock" do
      at = ~U[2026-09-10 12:00:00Z]
      assert {:alert, alert} = evaluate([observed: 20, baseline: 2.0], now: at)
      assert alert.at == at
    end
  end

  describe "baseline_for_window/3" do
    test "scales a historical count down to one window" do
      # 168 negatives across a week is one an hour.
      assert Detector.baseline_for_window(168, @week, @window) == 1.0
      assert Detector.baseline_for_window(336, @week, @window) == 2.0
    end

    test "is zero when there is no history to scale" do
      assert Detector.baseline_for_window(10, 0, @window) == 0.0
    end

    test "handles a window longer than the history" do
      assert Detector.baseline_for_window(10, @window, @week) == 1680.0
    end
  end

  describe "ratio/2" do
    test "is zero when nothing was observed, whatever the baseline" do
      assert Detector.ratio(0, 5.0) == 0.0
      assert Detector.ratio(0, 0) == 0.0
    end
  end

  defp evaluate(observation, opts \\ []) do
    {history_ms, opts} = Keyword.pop(opts, :history_ms, @week)
    total = Keyword.get(observation, :total, 0)

    Detector.evaluate(
      %{
        platform: :reddit,
        window_ms: @window,
        observed_negative: Keyword.fetch!(observation, :observed),
        observed_total: total,
        baseline_negative: Keyword.fetch!(observation, :baseline),
        history_ms: history_ms
      },
      opts
    )
  end
end
