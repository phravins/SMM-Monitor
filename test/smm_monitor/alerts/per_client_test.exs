defmodule SmmMonitor.Alerts.PerClientTest do
  @moduledoc """
  Alerting is scoped to a client.

  This is not cosmetic. Averaged across a book of clients, one client's
  bad afternoon disappears into four quiet ones — and an alert that
  reaches a shared Slack channel is useless if it doesn't say whose brand
  it concerns.
  """

  use SmmMonitor.DatabaseCase, async: false

  alias SmmMonitor.Alerts
  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.{Client, Clients, Mention, Monitor}

  defmodule CollectingNotifier do
    @moduledoc false
    @behaviour SmmMonitor.Alerts.Notifier

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def collected, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

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
    Clients.replace([client("Acme"), client("Beta")])

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

  test "a spike is raised against the client it belongs to" do
    seed_history("acme", 1)
    seed_history("beta", 1)
    seed_current("acme", 20)

    assert {:ok, [alert]} = Alerts.evaluate_now(start_alerts())

    assert alert.client_id == "acme"
    assert alert.client_name == "Acme"
    assert alert.platform == :reddit
  end

  test "the message names the client, since the channel is shared" do
    seed_history("acme", 1)
    seed_current("acme", 20)

    {:ok, [alert]} = Alerts.evaluate_now(start_alerts())

    assert Alert.message(alert) =~ "Acme / reddit"
  end

  test "a quiet client is not dragged into a noisy one's spike" do
    # Both clients on the same platform: only the one that spiked alerts.
    seed_history("acme", 1)
    seed_history("beta", 1)
    seed_current("acme", 20)
    seed_current("beta", 1)

    {:ok, alerts} = Alerts.evaluate_now(start_alerts())

    assert Enum.map(alerts, & &1.client_id) == ["acme"]
  end

  test "a noisy client is not hidden by quiet ones" do
    # The failure this scoping prevents: twenty negatives for Acme
    # averaged against three quiet clients looks like nothing at all.
    Clients.replace([client("Acme"), client("Beta"), client("Gamma"), client("Delta")])

    for id <- ~w(acme beta gamma delta), do: seed_history(id, 1)
    seed_current("acme", 20)

    {:ok, alerts} = Alerts.evaluate_now(start_alerts())

    assert Enum.map(alerts, & &1.client_id) == ["acme"]
  end

  test "one client's cooldown doesn't silence another's spike" do
    seed_history("acme", 1)
    seed_history("beta", 1)
    seed_current("acme", 20)

    alerts = start_alerts()
    {:ok, [_acme]} = Alerts.evaluate_now(alerts)

    # Acme is now cooling down. Beta spiking must still get through.
    seed_current("beta", 20, "beta-now")

    assert {:ok, [alert]} = Alerts.evaluate_now(alerts)
    assert alert.client_id == "beta"
  end

  test "the same client spiking again inside the cooldown stays quiet" do
    seed_history("acme", 1)
    seed_current("acme", 20)

    alerts = start_alerts()
    {:ok, [_first]} = Alerts.evaluate_now(alerts)

    assert {:ok, []} = Alerts.evaluate_now(alerts)
  end

  test "the dashboard sees only its own client's alerts" do
    seed_history("acme", 1)
    seed_history("beta", 1)
    seed_current("acme", 20)

    alerts = start_alerts()
    Alerts.evaluate_now(alerts)

    assert [%Alert{client_id: "acme"}] = Alerts.recent(alerts, 10, "acme")
    assert Alerts.recent(alerts, 10, "beta") == []
    # The operator can still see everything.
    assert length(Alerts.recent(alerts, 10, :all)) == 1
  end

  test "a paused client is not evaluated" do
    # Nothing is collected for a paused client, so its window empties and
    # every evaluation would read as a recovery.
    [acme, beta] = Clients.list()
    Clients.replace([acme, %{beta | active: false}])

    seed_history("acme", 1)
    seed_current("acme", 20)

    {:ok, alerts} = Alerts.evaluate_now(start_alerts())

    assert Enum.map(alerts, & &1.client_id) == ["acme"]
  end

  # --- helpers --------------------------------------------------------------

  defp client(name) do
    {:ok, client} = Client.new(%{name: name, keywords: [String.downcase(name)]})
    client
  end

  defp start_alerts do
    name = :"alerts_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Alerts, [name: name, schedule?: false]}, id: name)
    Ecto.Adapters.SQL.Sandbox.allow(SmmMonitor.Repo, self(), pid)
    pid
  end

  defp seed_history(client_id, per_hour) do
    now = DateTime.utc_now()

    mentions =
      for hour <- 1..(24 * 8), n <- 1..per_hour do
        Mention.new(%{
          id: "hist-#{client_id}-#{hour}-#{n}",
          platform: :reddit,
          client_id: client_id,
          author: "u/tester",
          text: "terrible and broken",
          sentiment: :negative,
          sentiment_value: -0.5,
          sentiment_score: -2,
          timestamp: DateTime.add(now, -hour * 3_600, :second)
        })
      end

    Persistence.store(mentions)
  end

  defp seed_current(client_id, count, prefix \\ "now") do
    now = DateTime.utc_now()

    Monitor.record_many(
      for index <- 1..count do
        %{
          id: "#{prefix}-#{client_id}-#{index}",
          platform: :reddit,
          client_id: client_id,
          author: "u/angry",
          text: "terrible and broken",
          timestamp: DateTime.add(now, -index * 30, :second)
        }
      end
    )
  end
end
