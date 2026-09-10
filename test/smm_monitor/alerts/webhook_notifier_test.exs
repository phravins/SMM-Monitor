defmodule SmmMonitor.Alerts.Notifiers.WebhookNotifierTest do
  @moduledoc """
  The webhook channel, exercised through a stub transport so nothing
  leaves the machine.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.Alerts.Notifiers.WebhookNotifier

  defmodule Stub do
    @moduledoc false
    def install(response), do: Process.put(:webhook_stub, %{response: response, sent: []})
    def sent, do: (Process.get(:webhook_stub) || %{sent: []}).sent |> Enum.reverse()

    def run(request) do
      state = Process.get(:webhook_stub)
      Process.put(:webhook_stub, %{state | sent: [request | state.sent]})
      {request, state.response}
    end
  end

  setup do
    original = Application.get_env(:smm_monitor, :alert_webhook_req_options)
    Application.put_env(:smm_monitor, :alert_webhook_req_options, adapter: Stub)
    System.put_env("SMM_ALERT_WEBHOOK_URL", "https://hooks.example.test/services/T/B/X")

    on_exit(fn ->
      System.delete_env("SMM_ALERT_WEBHOOK_URL")

      if original do
        Application.put_env(:smm_monitor, :alert_webhook_req_options, original)
      else
        Application.delete_env(:smm_monitor, :alert_webhook_req_options)
      end
    end)

    {:ok, alert: alert()}
  end

  describe "configured?/0" do
    test "is true when a URL is set" do
      assert WebhookNotifier.configured?()
    end

    test "is false without one" do
      System.delete_env("SMM_ALERT_WEBHOOK_URL")
      refute WebhookNotifier.configured?()
    end
  end

  describe "notify/1" do
    test "POSTs to the configured URL", %{alert: alert} do
      Stub.install(Req.Response.new(status: 200, body: "ok"))

      assert :ok = WebhookNotifier.notify(alert)

      assert [request] = Stub.sent()
      assert request.method == :post
      assert URI.to_string(request.url) =~ "hooks.example.test"
    end

    test "does nothing when no URL is configured", %{alert: alert} do
      System.delete_env("SMM_ALERT_WEBHOOK_URL")
      Stub.install(Req.Response.new(status: 200))

      # An unconfigured webhook is the normal state, not an error.
      assert :ok = WebhookNotifier.notify(alert)
      assert Stub.sent() == []
    end

    test "reports a rejected POST without raising", %{alert: alert} do
      Stub.install(Req.Response.new(status: 500, body: "nope"))

      log =
        capture_log(fn ->
          assert {:error, {:http_error, 500}} = WebhookNotifier.notify(alert)
        end)

      assert log =~ "webhook returned 500"
    end
  end

  describe "payload/1" do
    test "carries text a chat webhook can render", %{alert: alert} do
      payload = WebhookNotifier.payload(alert)

      assert payload.text =~ "reddit"
      assert payload.text =~ "negative mentions"
    end

    test "carries the raw numbers for a generic endpoint", %{alert: alert} do
      payload = WebhookNotifier.payload(alert)

      assert payload.observed_negative == 12
      assert payload.observed_total == 20
      assert payload.baseline_negative == 2.0
      assert payload.ratio == 6.0
      assert payload.severity == "critical"
      assert payload.platform == "reddit"
    end

    test "is JSON-encodable, including an infinite ratio", %{alert: alert} do
      # :infinity has no JSON representation, so it must not reach the encoder.
      infinite = %{alert | ratio: :infinity}

      assert {:ok, _json} = Jason.encode(WebhookNotifier.payload(infinite))
      assert WebhookNotifier.payload(infinite).ratio == nil
      assert {:ok, _json} = Jason.encode(WebhookNotifier.payload(alert))
    end
  end

  defp alert do
    %Alert{
      platform: :reddit,
      kind: :negative_spike,
      observed: 12,
      total: 20,
      baseline: 2.0,
      ratio: 6.0,
      severity: :critical,
      window_ms: :timer.hours(1),
      at: ~U[2026-09-10 12:00:00Z]
    }
  end
end
