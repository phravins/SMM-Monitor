defmodule SmmMonitor.Alerts.Conditions.SentimentThresholdTest do
  @moduledoc """
  "Are people unhappy?" — an absolute measure, so a brand that is
  reliably disliked still trips it, where a relative one never would.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Conditions.SentimentThreshold
  alias SmmMonitor.Client.AlertConfig

  doctest SentimentThreshold

  describe "evaluate/2" do
    test "alerts when the mean falls below the threshold" do
      assert {:alert, details} = evaluate(%{average: -0.45, count: 20})

      assert details.kind == :sentiment_drop
      assert details.observed == -0.45
      assert details.threshold == -0.3
    end

    test "alerts exactly on the threshold, not just past it" do
      # "drops below -0.3" reads as inclusive to anyone setting it.
      assert {:alert, _details} = evaluate(%{average: -0.3, count: 20})
    end

    test "stays quiet above the threshold" do
      assert {:ok, :below_threshold} = evaluate(%{average: -0.29, count: 20})
      assert {:ok, :below_threshold} = evaluate(%{average: 0.4, count: 20})
    end

    test "holds off until there are enough mentions to average" do
      # Three mentions averaging -0.4 is two annoyed customers, and the
      # number swings wildly on one more post.
      assert {:ok, :too_few_mentions} = evaluate(%{average: -0.9, count: 3})
    end

    test "the minimum is the client's own" do
      config = AlertConfig.new(%{sentiment_min_mentions: 2})

      assert {:alert, _details} = evaluate(%{average: -0.9, count: 3}, config)
    end

    test "a client can set their own threshold" do
      config = AlertConfig.new(%{sentiment_threshold: -0.7})

      assert {:ok, :below_threshold} = evaluate(%{average: -0.5, count: 20}, config)
      assert {:alert, _details} = evaluate(%{average: -0.8, count: 20}, config)
    end

    test "carries the numbers the alert has to show" do
      {:alert, details} = evaluate(%{average: -0.5, count: 30, negative: 22})

      assert details.count == 30
      assert details.negative == 22
    end

    test "a much worse average is critical rather than a warning" do
      assert {:alert, %{severity: :warning}} = evaluate(%{average: -0.4, count: 20})
      assert {:alert, %{severity: :critical}} = evaluate(%{average: -0.8, count: 20})
    end
  end

  describe "cleared?/2" do
    test "is not simply the opposite of alerting" do
      # An average sitting exactly on the threshold must not alert and
      # resolve alternately for as long as it stays there.
      on_the_line = %{average: -0.3, count: 20}

      assert {:alert, _details} = evaluate(on_the_line)
      refute SentimentThreshold.cleared?(on_the_line, AlertConfig.new())
    end

    test "clears once sentiment recovers past the margin" do
      config = AlertConfig.new()
      margin = SentimentThreshold.hysteresis()

      refute SentimentThreshold.cleared?(%{average: -0.3 + margin / 2, count: 20}, config)
      assert SentimentThreshold.cleared?(%{average: -0.3 + margin * 2, count: 20}, config)
    end

    test "clears when the window empties below the minimum sample" do
      # Nothing left to average is a recovery: the incident cannot be
      # said to be ongoing on two mentions.
      assert SentimentThreshold.cleared?(%{average: -0.9, count: 1}, AlertConfig.new())
    end
  end

  defp evaluate(observation, config \\ nil) do
    SentimentThreshold.evaluate(observation, config || AlertConfig.new())
  end
end
