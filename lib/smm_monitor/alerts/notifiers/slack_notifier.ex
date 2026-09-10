defmodule SmmMonitor.Alerts.Notifiers.WebhookNotifier do
  @moduledoc """
  POSTs alerts as JSON to a webhook — Slack-shaped by default, since
  that's where a social team already lives.

  The payload carries both a `text` field (which Slack, Discord and most
  chat webhooks render directly) and the raw numbers, so a generic
  endpoint gets something machine-readable rather than only prose.

  Silent unless `SMM_ALERT_WEBHOOK_URL` is set: an unconfigured webhook is
  the normal state, not an error.
  """

  @behaviour SmmMonitor.Alerts.Notifier

  require Logger

  alias SmmMonitor.Alerts.Alert

  @impl true
  def configured?, do: is_binary(url()) and String.trim(url()) != ""

  @doc "The configured webhook URL, if any."
  @spec url() :: String.t() | nil
  def url do
    System.get_env("SMM_ALERT_WEBHOOK_URL") || SmmMonitor.config(:alert_webhook_url)
  end

  @impl true
  def notify(%Alert{} = alert) do
    case url() do
      nil -> :ok
      "" -> :ok
      url -> post(url, alert)
    end
  end

  @doc """
  The JSON body sent for an alert. Public so its shape can be asserted
  without making an HTTP request.
  """
  @spec payload(Alert.t()) :: map()
  def payload(%Alert{} = alert) do
    %{
      text: ":rotating_light: #{Alert.message(alert)}",
      severity: to_string(alert.severity),
      platform: to_string(alert.platform),
      kind: to_string(alert.kind),
      observed_negative: alert.observed,
      observed_total: alert.total,
      baseline_negative: alert.baseline,
      ratio: ratio_value(alert.ratio),
      window_ms: alert.window_ms,
      at: DateTime.to_iso8601(alert.at)
    }
  end

  defp post(url, alert) do
    options =
      [
        url: url,
        method: :post,
        json: payload(alert),
        receive_timeout: 10_000,
        # One attempt. An alert is time-sensitive, and Req's default
        # retries would hold the alerting process for seconds while the
        # next evaluation queued behind it.
        retry: false
      ] ++ SmmMonitor.config(:alert_webhook_req_options, [])

    case options |> Req.new() |> Req.request() do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("alerts: webhook returned #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("alerts: webhook unreachable (#{inspect(reason)})")
        {:error, {:transport, reason}}
    end
  end

  # :infinity isn't representable in JSON.
  defp ratio_value(:infinity), do: nil
  defp ratio_value(ratio), do: Float.round(ratio / 1, 2)
end
