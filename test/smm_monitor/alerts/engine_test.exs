defmodule SmmMonitor.Alerts.EngineTest do
  @moduledoc """
  The alerting process end to end: real mentions in the store, real
  thresholds on a client, and the incident state machine that decides
  how many messages a problem is worth.

  The behaviour this file exists to protect is the one that decides
  whether anyone keeps the channel unmuted: **one alert per incident,
  and one all-clear when it ends** — not one per evaluation.
  """

  use SmmMonitor.DatabaseCase, async: false

  alias SmmMonitor.Alerts
  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.{Client, Clients, Monitor}

  defmodule CollectingNotifier do
    @moduledoc false
    @behaviour SmmMonitor.Alerts.Notifier

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def collected, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
    def clear, do: Agent.update(__MODULE__, fn _state -> [] end)

    @impl true
    def configured?, do: true

    @impl true
    def notify(alert) do
      Agent.update(__MODULE__, &[alert | &1])
      :ok
    end
  end

  setup do
    Monitor.reset()
    start_supervised!(%{id: CollectingNotifier, start: {CollectingNotifier, :start, []}})

    original_notifiers = Application.get_env(:smm_monitor, :alert_notifiers)
    Application.put_env(:smm_monitor, :alert_notifiers, [CollectingNotifier])

    original_clients = Clients.list()
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), Process.whereis(Clients))

    on_exit(fn ->
      Clients.replace(original_clients)

      if original_notifiers do
        Application.put_env(:smm_monitor, :alert_notifiers, original_notifiers)
      else
        Application.delete_env(:smm_monitor, :alert_notifiers)
      end
    end)

    :ok
  end

  describe "sentiment alerts" do
    test "fire when a client's mean sentiment falls below their threshold" do
      set_client()
      record_negative(20)

      assert {:ok, [alert]} = Alerts.evaluate_now(start_alerts())

      assert alert.kind == :sentiment_drop
      assert alert.client_name == "Acme"
      assert alert.state == :firing
      assert alert.details.observed < -0.3
    end

    test "stay quiet while sentiment is healthy" do
      set_client()
      record_positive(20)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
      assert CollectingNotifier.collected() == []
    end

    test "respect a client's own threshold" do
      # Mentions averaging about -0.5: past the default -0.3, nowhere
      # near this client's -0.9.
      set_client(%{sentiment_threshold: -0.9})
      record(20, "realoffice was down again this morning", :negative)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end

    test "and the default catches what a stricter threshold would miss" do
      set_client()
      record(20, "realoffice was down again this morning", :negative)

      assert {:ok, [%Alert{kind: :sentiment_drop}]} = Alerts.evaluate_now(start_alerts())
    end
  end

  describe "watch phrase alerts" do
    test "fire on a single mention containing the phrase" do
      set_client(%{watch_phrases: ["lawsuit"]})
      record(1, "we are considering a lawsuit over this", :neutral)

      assert {:ok, [alert]} = Alerts.evaluate_now(start_alerts())

      assert alert.kind == :watch_phrase
      assert alert.subject == "lawsuit"
      assert alert.severity == :critical
      assert alert.details.excerpt =~ "lawsuit"
    end

    test "do not fire for a client who didn't ask for that phrase" do
      set_client(%{watch_phrases: ["refund"]})
      record(1, "we are considering a lawsuit over this", :neutral)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end

    test "two phrases in the window are two separate alerts" do
      set_client(%{watch_phrases: ["lawsuit", "refund"]})
      record(1, "considering a lawsuit", :neutral)
      record(1, "still waiting on a refund", :neutral)

      {:ok, alerts} = Alerts.evaluate_now(start_alerts())

      assert Enum.sort(Enum.map(alerts, & &1.subject)) == ["lawsuit", "refund"]
    end
  end

  describe "one alert per incident" do
    test "a condition that stays true notifies once, not on every evaluation" do
      # Sixty Slack messages an hour for one bad afternoon is how a
      # channel gets muted.
      set_client()
      record_negative(20)
      alerts = start_alerts()

      assert {:ok, [_first]} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)

      assert length(CollectingNotifier.collected()) == 1
    end

    test "the incident stays visible while it runs" do
      set_client()
      record_negative(20)
      alerts = start_alerts()

      Alerts.evaluate_now(alerts)
      Alerts.evaluate_now(alerts)

      assert [incident] = Alerts.active(alerts)
      assert incident.alert.kind == :sentiment_drop
      assert incident.occurrences == 2
    end

    test "a worsening spike updates the numbers without re-notifying" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      [before] = Alerts.active(alerts)

      # It gets worse.
      record(30, "absolutely terrible, worst support, broken and useless", :negative)
      Alerts.evaluate_now(alerts)

      [after_worsening] = Alerts.active(alerts)

      assert after_worsening.alert.details.count > before.alert.details.count
      assert length(CollectingNotifier.collected()) == 1
    end

    test "counts raised and resolved separately" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      stats = Alerts.stats(alerts)
      assert stats.raised == 1
      assert stats.resolved == 0
    end
  end

  describe "resolving" do
    test "sends an all-clear when the condition recovers" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      assert {:ok, [_firing]} = Alerts.evaluate_now(alerts)

      # The bad mentions age out and good ones replace them.
      Monitor.reset()
      record_positive(20)

      assert {:ok, [resolved]} = Alerts.evaluate_now(alerts)

      assert resolved.state == :resolved
      assert resolved.kind == :sentiment_drop
      assert Alert.message(resolved) =~ "recovered"
    end

    test "the all-clear says how long it lasted" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      Monitor.reset()
      record_positive(20)
      {:ok, [resolved]} = Alerts.evaluate_now(alerts)

      assert resolved.opened_at
      assert Alert.message(resolved) =~ "lasted"
    end

    test "the incident is no longer active afterwards" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)
      assert [_incident] = Alerts.active(alerts)

      Monitor.reset()
      record_positive(20)
      Alerts.evaluate_now(alerts)

      assert Alerts.active(alerts) == []
      assert Alerts.stats(alerts).resolved == 1
    end

    test "resolves exactly once, not on every quiet evaluation afterwards" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      Monitor.reset()
      record_positive(20)
      Alerts.evaluate_now(alerts)
      Alerts.evaluate_now(alerts)
      Alerts.evaluate_now(alerts)

      states = Enum.map(CollectingNotifier.collected(), & &1.state)
      assert states == [:firing, :resolved]
    end

    test "a new incident after a recovery alerts again" do
      set_client()
      record_negative(20)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      Monitor.reset()
      record_positive(20)
      Alerts.evaluate_now(alerts)

      # It goes bad again — that is a new incident, not a muted one.
      Monitor.reset()
      record_negative(20)
      assert {:ok, [alert]} = Alerts.evaluate_now(alerts)
      assert alert.state == :firing

      assert Enum.map(CollectingNotifier.collected(), & &1.state) ==
               [:firing, :resolved, :firing]
    end

    test "a watch phrase resolves when it leaves the window" do
      set_client(%{watch_phrases: ["lawsuit"]})
      record(1, "considering a lawsuit", :neutral)
      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      Monitor.reset()
      record(5, "everything is fine now", :neutral)

      assert {:ok, [resolved]} = Alerts.evaluate_now(alerts)
      assert resolved.state == :resolved
      assert resolved.subject == "lawsuit"
    end
  end

  describe "not flapping" do
    test "sentiment on the threshold does not alternate between alert and clear" do
      # The margin is the whole point: without it a number sitting on the
      # line produces a message a minute, alternating firing and resolved.
      set_client(%{sentiment_threshold: -0.25, sentiment_min_mentions: 1})
      record(10, "realoffice is slow", :negative)
      alerts = start_alerts()

      assert {:ok, [_firing]} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)
      assert {:ok, []} = Alerts.evaluate_now(alerts)

      assert length(CollectingNotifier.collected()) == 1
    end
  end

  describe "scoping" do
    test "one client's incident doesn't silence another's" do
      acme = client("Acme")
      beta = client("Beta")
      Clients.replace([acme, beta])

      record_negative(20, "acme")
      record_negative(20, "beta")

      {:ok, alerts} = Alerts.evaluate_now(start_alerts())

      assert Enum.sort(Enum.map(alerts, & &1.client_id)) == ["acme", "beta"]
    end

    test "the dashboard sees only its own client's alerts" do
      acme = client("Acme")
      beta = client("Beta")
      Clients.replace([acme, beta])
      record_negative(20, "acme")

      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      assert [%Alert{client_id: "acme"}] = Alerts.recent(alerts, 10, "acme")
      assert Alerts.recent(alerts, 10, "beta") == []
    end

    test "a paused client is not evaluated" do
      acme = client("Acme")
      Clients.replace([%{acme | active: false}])
      record_negative(20)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end

    test "a client with alerting switched off is not evaluated" do
      set_client(%{enabled: false})
      record_negative(20)

      assert {:ok, []} = Alerts.evaluate_now(start_alerts())
    end
  end

  describe "notifier failures" do
    defmodule BrokenNotifier do
      @moduledoc false
      @behaviour SmmMonitor.Alerts.Notifier

      @impl true
      def configured?, do: true

      @impl true
      def notify(_alert), do: raise("this channel is down")
    end

    test "a broken channel doesn't stop the alert reaching the others" do
      Application.put_env(:smm_monitor, :alert_notifiers, [BrokenNotifier, CollectingNotifier])
      set_client()
      record_negative(20)

      assert {:ok, [_alert]} = Alerts.evaluate_now(start_alerts())
      assert length(CollectingNotifier.collected()) == 1
    end

    test "and doesn't crash the alerting process" do
      Application.put_env(:smm_monitor, :alert_notifiers, [BrokenNotifier])
      set_client()
      record_negative(20)

      alerts = start_alerts()
      Alerts.evaluate_now(alerts)

      assert Process.alive?(alerts)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp start_alerts do
    name = :"alerts_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Alerts, [name: name, schedule?: false]}, id: name)
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), pid)
    pid
  end

  defp client(name, alert_attrs \\ %{}) do
    {:ok, client} =
      Client.new(%{
        name: name,
        keywords: [String.downcase(name)],
        alerts: AlertConfig.new(alert_attrs)
      })

    client
  end

  defp set_client(alert_attrs \\ %{}) do
    Clients.replace([client("Acme", alert_attrs)])
  end

  defp record_negative(count, client_id \\ "acme") do
    record(count, "absolutely terrible, worst support, broken and useless", :negative, client_id)
  end

  defp record_positive(count, client_id \\ "acme") do
    record(count, "excellent, brilliant, fantastic work", :positive, client_id)
  end

  defp record(count, text, _sentiment, client_id \\ "acme") do
    now = DateTime.utc_now()

    Monitor.record_many(
      for index <- 1..count do
        %{
          id: "m-#{client_id}-#{System.unique_integer([:positive])}",
          platform: :reddit,
          client_id: client_id,
          author: "u/tester",
          text: text,
          timestamp: DateTime.add(now, -index, :second)
        }
      end
    )

    :ok
  end
end
