defmodule SmmMonitor.Alerts.Conditions.VolumeSpikeTest do
  @moduledoc """
  "Is this louder than normal *for this client*?" — relative, because
  twenty mentions is a story for a quiet brand and a Tuesday for a loud
  one.
  """

  use ExUnit.Case, async: true

  alias SmmMonitor.Alerts.Conditions.VolumeSpike
  alias SmmMonitor.Client.AlertConfig

  doctest VolumeSpike

  describe "evaluate/2" do
    test "alerts when volume reaches the multiple of normal" do
      assert {:alert, details} = evaluate(%{count: 30, baseline: baseline(5.0)})

      assert details.kind == :volume_spike
      assert details.observed == 30
      assert details.baseline == 5.0
      assert details.ratio == 6.0
    end

    test "stays quiet at normal volume" do
      assert {:ok, :below_threshold} = evaluate(%{count: 12, baseline: baseline(10.0)})
    end

    test "the multiple is the client's own" do
      jumpy = AlertConfig.new(%{volume_multiple: 1.5})

      assert {:alert, _details} = evaluate(%{count: 16, baseline: baseline(10.0)}, jumpy)
      assert {:ok, :below_threshold} = evaluate(%{count: 16, baseline: baseline(10.0)})
    end

    test "a quiet client's tenfold spike of two mentions is not an alert" do
      # Without the floor, the quietest clients alert the most — which is
      # exactly backwards.
      assert {:ok, :below_threshold} = evaluate(%{count: 2, baseline: baseline(0.2)})
    end

    test "the floor is the client's own" do
      sensitive = AlertConfig.new(%{volume_floor: 2})

      assert {:alert, _details} = evaluate(%{count: 2, baseline: baseline(0.2)}, sensitive)
    end

    test "a client with no usual level at this hour still alerts once past the floor" do
      assert {:alert, %{ratio: :infinity, severity: :critical}} =
               evaluate(%{count: 25, baseline: baseline(0.0, 5)})
    end
  end

  describe "warming up" do
    test "a brand new client is never a spike" do
      # You cannot detect an anomaly without a normal, and a client added
      # this morning has none.
      assert {:ok, :warming_up} = evaluate(%{count: 100, baseline: baseline(0.0, 0)})
    end

    test "one day of history is still not enough" do
      assert {:ok, :warming_up} = evaluate(%{count: 100, baseline: baseline(2.0, 1)})
    end

    test "two days is" do
      assert {:alert, _details} = evaluate(%{count: 100, baseline: baseline(2.0, 2)})
    end

    test "the alert says how much history it rests on" do
      {:alert, details} = evaluate(%{count: 100, baseline: baseline(2.0, 3)})

      assert details.days_observed == 3
    end
  end

  describe "severity" do
    test "a big spike is a warning, a huge one is critical" do
      assert {:alert, %{severity: :warning}} = evaluate(%{count: 30, baseline: baseline(8.0)})
      assert {:alert, %{severity: :critical}} = evaluate(%{count: 100, baseline: baseline(8.0)})
    end
  end

  describe "context for the reader" do
    test "carries the window's sentiment, since volume alone isn't bad news" do
      # A product launch and a data breach look identical here; the
      # sentiment is what separates them.
      {:alert, details} =
        evaluate(%{count: 30, baseline: baseline(5.0), average_sentiment: 0.6})

      assert details.average_sentiment == 0.6
    end
  end

  describe "cleared?/2" do
    test "does not clear the moment it drops below the trigger" do
      # Volume hovering either side of the line would otherwise alert and
      # resolve every minute for as long as the story ran.
      just_below = %{count: 29, baseline: baseline(10.0)}

      assert {:ok, :below_threshold} = evaluate(just_below)
      refute VolumeSpike.cleared?(just_below, AlertConfig.new())
    end

    test "clears once volume falls well back" do
      assert VolumeSpike.cleared?(%{count: 15, baseline: baseline(10.0)}, AlertConfig.new())
    end

    test "clears when volume falls below the floor whatever the ratio" do
      assert VolumeSpike.cleared?(%{count: 3, baseline: baseline(0.1)}, AlertConfig.new())
    end
  end

  defp evaluate(observation, config \\ nil) do
    VolumeSpike.evaluate(observation, config || AlertConfig.new())
  end

  defp baseline(average, days_observed \\ 7) do
    %{average: average, days_observed: days_observed, samples: []}
  end
end
