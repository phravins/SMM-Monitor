defmodule SmmMonitor.Alerts.Notifiers.SlackNotifierTest do
  @moduledoc """
  What actually reaches Slack. The HTTP call is stubbed throughout —
  a test suite that posts to a real webhook is a test suite nobody can
  run twice.
  """

  use SmmMonitor.ClientCase, async: false

  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Alerts.Notifiers.SlackNotifier
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.{Mention, SlackStub}

  setup do
    original = Application.get_env(:smm_monitor, :alert_webhook_url)
    System.delete_env("SMM_ALERT_WEBHOOK_URL")

    on_exit(fn ->
      if original do
        Application.put_env(:smm_monitor, :alert_webhook_url, original)
      else
        Application.delete_env(:smm_monitor, :alert_webhook_url)
      end

      Application.delete_env(:smm_monitor, :alert_webhook_req_options)
    end)

    :ok
  end

  describe "the payload Slack receives" do
    test "leads with a text fallback, for notifications and simple clients" do
      payload = SlackNotifier.payload(sentiment_alert())

      assert payload.text =~ "Acme"
      assert payload.text =~ "sentiment fell to -0.42"
      # The icon is what makes it scannable in a busy channel.
      assert payload.text =~ ":rotating_light:" or payload.text =~ ":warning:"
    end

    test "renders blocks, which is what Slack does well" do
      payload = SlackNotifier.payload(sentiment_alert())

      assert [%{type: "section"} = headline, %{type: "section", fields: fields}] = payload.blocks
      assert headline.text.text =~ "Acme"
      assert length(fields) == 4
    end

    test "the fields carry the evidence, not just the verdict" do
      payload = SlackNotifier.payload(sentiment_alert())
      [_headline, %{fields: fields}] = payload.blocks
      text = Enum.map_join(fields, " ", & &1.text)

      assert text =~ "Average sentiment"
      assert text =~ "-0.42"
      assert text =~ "Threshold"
      assert text =~ "24"
    end

    test "carries machine-readable metadata for non-Slack endpoints" do
      # A Discord relay or a script gets numbers rather than prose.
      payload = SlackNotifier.payload(sentiment_alert())

      assert payload.metadata.kind == "sentiment_drop"
      assert payload.metadata.state == "firing"
      assert payload.metadata.client_id == "acme"
      assert payload.metadata.details.observed == -0.42
    end

    test "is JSON-encodable, including an infinite ratio" do
      # :infinity has no JSON representation and would raise on encode.
      alert = volume_alert(:infinity)

      assert {:ok, json} = alert |> SlackNotifier.payload() |> Jason.encode()
      assert json =~ "volume_spike"
    end

    test "a watch phrase alert quotes the mention" do
      payload = SlackNotifier.payload(phrase_alert())

      assert payload.text =~ "lawsuit"
      context = Enum.find(payload.blocks, &(&1[:type] == "context"))
      assert context.elements |> hd() |> Map.get(:text) =~ "considering a lawsuit"
    end

    test "a volume alert says what normal was" do
      payload = SlackNotifier.payload(volume_alert(6.0))
      [_headline, %{fields: fields}] = payload.blocks
      text = Enum.map_join(fields, " ", & &1.text)

      assert text =~ "Usual for this hour"
      assert text =~ "6.00x"
    end
  end

  describe "resolved alerts" do
    test "look different from firing ones at a glance" do
      payload = SlackNotifier.payload(resolved_alert())

      assert payload.text =~ ":white_check_mark:"
      [headline | _rest] = payload.blocks
      assert headline.text.text =~ "Resolved"
    end

    test "say how long the incident lasted" do
      payload = SlackNotifier.payload(resolved_alert())

      context = Enum.find(payload.blocks, &(&1[:type] == "context"))
      assert context.elements |> hd() |> Map.get(:text) =~ "Lasted 40 min"
    end

    test "are marked as resolved in the metadata" do
      assert SlackNotifier.payload(resolved_alert()).metadata.state == "resolved"
    end
  end

  describe "choosing the webhook" do
    test "uses the global URL by default" do
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")

      assert SlackNotifier.url_for(sentiment_alert()) == "https://hooks.slack.com/global"
    end

    test "a client's own URL wins over the global one" do
      # An alert in two channels gets acknowledged in neither.
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      set_clients([client_with_webhook("https://hooks.slack.com/acme")])

      assert SlackNotifier.url_for(sentiment_alert()) == "https://hooks.slack.com/acme"
    end

    test "a client without one falls back to the global" do
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      set_clients(["Acme"])

      assert SlackNotifier.url_for(sentiment_alert()) == "https://hooks.slack.com/global"
    end

    test "with nothing configured anywhere, there is nowhere to send" do
      set_clients(["Acme"])

      assert SlackNotifier.url_for(sentiment_alert()) == nil
      refute SlackNotifier.configured?()
    end

    test "a client webhook alone is enough to make the notifier configured" do
      # Otherwise an agency that only routes one client to Slack would
      # have the notifier skipped entirely.
      set_clients([client_with_webhook("https://hooks.slack.com/acme")])

      assert SlackNotifier.configured?()
    end
  end

  describe "delivery" do
    test "posts the payload to the configured URL" do
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      stub(SlackStub.ok())

      assert :ok = SlackNotifier.notify(sentiment_alert())

      assert [{:post, url, body}] = requests()
      assert url == "https://hooks.slack.com/global"
      assert body["text"] =~ "Acme"
      assert is_list(body["blocks"])
    end

    test "says nothing and succeeds when no webhook is configured" do
      set_clients(["Acme"])

      assert :ok = SlackNotifier.notify(sentiment_alert())
      assert requests() == []
    end

    test "a rejected post is reported, not raised" do
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      stub(SlackStub.no_service())

      assert {:error, {:http_error, 404}} = SlackNotifier.notify(sentiment_alert())
    end

    test "an unreachable Slack is reported, not raised" do
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      stub(%Req.TransportError{reason: :timeout})

      assert {:error, {:transport, _reason}} = SlackNotifier.notify(sentiment_alert())
    end

    test "does not retry — an alert is time-sensitive" do
      # Req's default retries would hold the alerting process for seconds
      # while the next evaluation queued behind it.
      Application.put_env(:smm_monitor, :alert_webhook_url, "https://hooks.slack.com/global")
      stub(Req.Response.new(status: 500, body: ""))

      SlackNotifier.notify(sentiment_alert())

      assert length(requests()) == 1
    end
  end

  # --- helpers --------------------------------------------------------------

  defp stub(response) do
    SlackStub.install(response)
    Application.put_env(:smm_monitor, :alert_webhook_req_options, SlackStub.req_options())
  end

  defp requests, do: SlackStub.requests()

  defp client_with_webhook(url) do
    build_client("Acme", alerts: AlertConfig.new(%{webhook_url: url}))
  end

  defp sentiment_alert do
    %Alert{
      kind: :sentiment_drop,
      client_id: "acme",
      client_name: "Acme",
      severity: :critical,
      window_ms: :timer.hours(1),
      at: ~U[2026-09-12 12:00:00Z],
      opened_at: ~U[2026-09-12 12:00:00Z],
      details: %{observed: -0.42, threshold: -0.3, count: 24, negative: 18}
    }
  end

  defp volume_alert(ratio) do
    %Alert{
      kind: :volume_spike,
      client_id: "acme",
      client_name: "Acme",
      severity: :warning,
      window_ms: :timer.hours(1),
      at: ~U[2026-09-12 12:00:00Z],
      opened_at: ~U[2026-09-12 12:00:00Z],
      details: %{observed: 42, baseline: 7.0, ratio: ratio, days_observed: 7}
    }
  end

  defp phrase_alert do
    %Alert{
      kind: :watch_phrase,
      client_id: "acme",
      client_name: "Acme",
      subject: "lawsuit",
      severity: :critical,
      window_ms: :timer.hours(1),
      at: ~U[2026-09-12 12:00:00Z],
      opened_at: ~U[2026-09-12 12:00:00Z],
      details: %{
        observed: 2,
        excerpt: "we are considering a lawsuit",
        mention:
          Mention.new(%{
            id: "m1",
            platform: :reddit,
            author: "u/x",
            text: "x",
            timestamp: DateTime.utc_now()
          })
      }
    }
  end

  defp resolved_alert do
    %{
      sentiment_alert()
      | state: :resolved,
        severity: :warning,
        opened_at: ~U[2026-09-12 12:00:00Z],
        at: ~U[2026-09-12 12:40:00Z],
        details: %{observed: 0.1, threshold: -0.3, count: 30}
    }
  end
end
