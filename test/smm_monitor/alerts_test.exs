defmodule SmmMonitor.AlertsTest do
  @moduledoc """
  The alerting process: turning a real spike in the stored data into a
  notification, exactly once.

  Each test drives `evaluate_now/1` rather than waiting for the timer, and
  runs its own Alerts process so cooldown state can't leak between tests.
  """

  use SmmMonitor.DatabaseCase, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Alerts
  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Monitor

  defmodule CollectingNotifier do
    @moduledoc false
    @behaviour SmmMonitor.Alerts.Notifier

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def collected, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

    @impl true
    def configured?, do: true

    @impl true
    def notify(alert) do
      Agent.update(__MODULE__, &[alert | &1])
      :ok
    end
  end

  defmodule BrokenNotifier do
    @moduledoc false
    @behaviour SmmMonitor.Alerts.Notifier

    @impl true
    def configured?, do: true

    @impl true
    def notify(_alert), do: raise("this channel is down")
  end

  setup do
    Monitor.reset()
    start_supervised!(%{id: CollectingNotifier, start: {CollectingNotifier, :start, []}})

    original = Application.get_env(:smm_monitor, :alert_notifiers)
    Application.put_env(:smm_monitor, :alert_notifiers, [CollectingNotifier])

    on_exit(fn ->
      if original do
        Application.put_env(:smm_monitor, :alert_notifiers, original)
      else
        Application.delete_env(:smm_monitor, :alert_notifiers)
      end
    end)

    :ok
  end

  describe "a quiet platform" do
    test "raises nothing" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 1)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
      assert CollectingNotifier.collected() == []
    end
  end

  describe "a spike" do
    test "raises an alert and notifies" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      assert {:ok, [alert]} = Alerts.evaluate_now(start_alerts())

      assert alert.platform == :reddit
      assert alert.observed >= 20
      assert [%Alert{}] = CollectingNotifier.collected()
    end

    test "the alert says what was seen and what is normal" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      {:ok, [alert]} = Alerts.evaluate_now(start_alerts())
      message = Alert.message(alert)

      assert message =~ "reddit"
      assert message =~ "negative mentions"
      assert message =~ "above baseline"
    end

    test "shows up in recent/2 for the dashboard" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      assert [%Alert{platform: :reddit}] = Alerts.recent(alerts, 10)
    end
  end

  describe "cooldowns" do
    test "a persisting spike alerts once, not on every evaluation" do
      # Without this a single bad afternoon would post to Slack sixty
      # times an hour.
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      alerts = start_alerts()

      assert {:ok, [_alert]} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)

      assert length(CollectingNotifier.collected()) == 1
    end

    test "recovering below threshold clears the cooldown" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      alerts = start_alerts()
      assert {:ok, [_alert]} = Alerts.evaluate_now(alerts)

      # The spike passes.
      Monitor.reset()
      seed_current(negatives: 1)
      assert {:ok, []} = Alerts.evaluate_now(alerts)

      # A genuinely new spike must alert immediately, not wait out the
      # remainder of the old cooldown.
      seed_current(negatives: 20, prefix: "second")
      assert {:ok, [_alert]} = Alerts.evaluate_now(alerts)
      assert length(CollectingNotifier.collected()) == 2
    end

    test "a zero cooldown alerts on every evaluation" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      with_config(:alert_cooldown_ms, 0, fn ->
        alerts = start_alerts()
        assert {:ok, [_first]} = Alerts.evaluate_now(alerts)
        assert {:ok, [_second]} = Alerts.evaluate_now(alerts)
      end)
    end
  end

  describe "warming up" do
    test "stays quiet with no stored history at all" do
      # Nothing in the database means no baseline, which must read as
      # "don't know yet" rather than "everything is a spike".
      seed_current(negatives: 50)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end

    test "stays quiet when history is shorter than the warm-up" do
      seed_history(negatives_per_hour: 1, hours: 4)
      seed_current(negatives: 50)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end
  end

  describe "notifier failures" do
    test "one broken channel doesn't stop the others" do
      Application.put_env(:smm_monitor, :alert_notifiers, [BrokenNotifier, CollectingNotifier])

      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      log = capture_log(fn -> Alerts.evaluate_now(start_alerts()) end)

      assert log =~ "BrokenNotifier"
      # The working channel still received it.
      assert [%Alert{}] = CollectingNotifier.collected()
    end

    test "a broken channel doesn't crash the alerting process" do
      Application.put_env(:smm_monitor, :alert_notifiers, [BrokenNotifier])

      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      alerts = start_alerts()
      capture_log(fn -> Alerts.evaluate_now(alerts) end)

      assert Process.alive?(alerts)
      assert %{raised: 1} = Alerts.stats(alerts)
    end
  end

  describe "stats/1" do
    test "reports evaluations, raises and active cooldowns" do
      seed_history(negatives_per_hour: 1)
      seed_current(negatives: 20)

      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      stats = Alerts.stats(alerts)
      assert stats.evaluations == 1
      assert stats.raised == 1
      assert {"unassigned", :reddit, :negative_spike} in stats.cooling_down
      assert %DateTime{} = stats.last_evaluated_at
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start_alerts do
    name = :"alerts_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Alerts, [name: name, schedule?: false]}, id: name)
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), pid)
    pid
  end

  # Stored history, which is where the baseline comes from.
  defp seed_history(opts) do
    hours = Keyword.get(opts, :hours, 24 * 8)
    per_hour = Keyword.get(opts, :negatives_per_hour, 1)
    now = DateTime.utc_now()

    mentions =
      for hour <- 1..hours, n <- 1..per_hour do
        mention(
          id: "hist-#{hour}-#{n}",
          platform: :reddit,
          text: "realoffice is terrible and broken",
          sentiment: :negative,
          sentiment_score: -2,
          timestamp: DateTime.add(now, -hour * 3_600, :second)
        )
      end

    Persistence.store(mentions)
  end

  # The current window, which is read from ETS.
  defp seed_current(opts) do
    count = Keyword.fetch!(opts, :negatives)
    prefix = Keyword.get(opts, :prefix, "now")
    now = DateTime.utc_now()

    Monitor.record_many(
      for index <- 1..count do
        %{
          id: "#{prefix}-#{index}",
          platform: :reddit,
          author: "u/angry",
          text: "realoffice is terrible and broken",
          timestamp: DateTime.add(now, -index * 30, :second)
        }
      end
    )
  end

  defp with_config(key, value, fun) do
    # `original` is bound outside the try, because a function-level
    # `after` can't see bindings made in the body.
    original = Application.get_env(:smm_monitor, key)
    Application.put_env(:smm_monitor, key, value)

    try do
      fun.()
    after
      restore_config(key, original)
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:smm_monitor, key)
  defp restore_config(key, value), do: Application.put_env(:smm_monitor, key, value)
end
