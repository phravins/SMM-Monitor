defmodule SmmMonitor.Alerts.Notifiers.SlackNotifier do
  @moduledoc """
  POSTs alerts to a Slack incoming webhook.

  Slack because that is where a social team already is: an alert that
  arrives where someone is already looking gets acted on, and one in a
  mailbox gets read tomorrow.

  ## Which webhook

  A **global** URL (`SMM_ALERT_WEBHOOK_URL`) is the default, and any
  client may **override** it with one of their own. Both, rather than
  one:

    * global alone would mean every client's alerts land in one channel —
      right for a small agency, and unusable the moment a channel is
      shared *with* a client, since they would see everyone else's;
    * per-client alone would mean setting a URL on every client before
      any alerting works at all, which is a poor first five minutes.

  So the global one covers the common case and the override exists for
  the client who needs their own channel. A client with an override and
  a global set sends only to the override — an alert in two channels
  gets acknowledged in neither.

  ## Payload

  `blocks` for the rendering Slack does well, plus a `text` fallback for
  notifications and clients that don't render blocks, plus the raw
  numbers under `metadata` so a generic endpoint (Discord, a webhook
  relay, a script) gets something machine-readable rather than prose.

  Silent unless a URL is configured somewhere: an unconfigured webhook is
  the normal state, not an error.
  """

  @behaviour SmmMonitor.Alerts.Notifier

  require Logger

  alias SmmMonitor.Alerts.Alert
  alias SmmMonitor.{Client, Clients}

  @impl true
  def configured?, do: present?(global_url()) or any_client_url?()

  @doc "The global webhook URL, if any."
  @spec global_url() :: String.t() | nil
  def global_url do
    System.get_env("SMM_ALERT_WEBHOOK_URL") || SmmMonitor.config(:alert_webhook_url)
  end

  @doc """
  The URL an alert should go to: the client's own if they have one, the
  global otherwise.
  """
  @spec url_for(Alert.t()) :: String.t() | nil
  def url_for(%Alert{client_id: nil}), do: global_url()

  def url_for(%Alert{client_id: client_id}) do
    case client_url(client_id) do
      nil -> global_url()
      url -> url
    end
  end

  @impl true
  def notify(%Alert{} = alert) do
    case url_for(alert) do
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
      text: "#{icon(alert)} #{Alert.message(alert)}",
      blocks: blocks(alert),
      metadata: metadata(alert)
    }
  end

  # --- payload ---------------------------------------------------------------

  defp blocks(%Alert{} = alert) do
    [
      %{
        type: "section",
        text: %{type: "mrkdwn", text: "#{icon(alert)} *#{headline(alert)}*"}
      },
      %{type: "section", fields: fields(alert)}
    ] ++ context_block(alert)
  end

  defp headline(%Alert{state: :resolved} = alert) do
    "Resolved — #{Alert.kind_label(alert.kind)}: #{client_name(alert)}"
  end

  defp headline(%Alert{} = alert) do
    "#{String.upcase(Alert.kind_label(alert.kind))}: #{client_name(alert)}"
  end

  defp fields(%Alert{} = alert) do
    alert
    |> field_pairs()
    |> Enum.map(fn {label, value} ->
      %{type: "mrkdwn", text: "*#{label}*\n#{value}"}
    end)
  end

  defp field_pairs(%Alert{kind: :sentiment_drop, details: details} = alert) do
    [
      {"Average sentiment", format(details[:observed])},
      {"Threshold", format(details[:threshold])},
      {"Mentions", "#{details[:count]} (#{details[:negative] || 0} negative)"},
      {"Window", Alert.window_label(alert.window_ms)}
    ]
  end

  defp field_pairs(%Alert{kind: :volume_spike, details: details} = alert) do
    [
      {"Mentions", to_string(details[:observed])},
      {"Usual for this hour", format(details[:baseline])},
      {"Above normal", ratio_label(details[:ratio])},
      {"Window", Alert.window_label(alert.window_ms)}
    ]
  end

  defp field_pairs(%Alert{kind: :watch_phrase, subject: phrase, details: details} = alert) do
    [
      {"Phrase", "`#{phrase}`"},
      {"Mentions", to_string(details[:observed])},
      {"Window", Alert.window_label(alert.window_ms)}
    ]
  end

  defp field_pairs(%Alert{} = alert) do
    [{"Client", client_name(alert)}, {"Window", Alert.window_label(alert.window_ms)}]
  end

  # The quoted mention for a phrase alert, and how long a resolved
  # incident ran — the two things a reader asks for that don't fit in a
  # field.
  defp context_block(%Alert{kind: :watch_phrase, details: %{excerpt: excerpt}})
       when is_binary(excerpt) and excerpt != "" do
    [%{type: "context", elements: [%{type: "mrkdwn", text: "> #{excerpt}"}]}]
  end

  defp context_block(%Alert{state: :resolved} = alert) do
    minutes = alert |> Alert.duration_ms() |> div(60_000)
    [%{type: "context", elements: [%{type: "mrkdwn", text: "Lasted #{minutes} min"}]}]
  end

  defp context_block(%Alert{}), do: []

  defp metadata(%Alert{} = alert) do
    %{
      kind: to_string(alert.kind),
      state: to_string(alert.state),
      severity: to_string(alert.severity),
      client_id: alert.client_id,
      client_name: alert.client_name,
      subject: alert.subject,
      window_ms: alert.window_ms,
      at: DateTime.to_iso8601(alert.at),
      opened_at: alert.opened_at && DateTime.to_iso8601(alert.opened_at),
      details: json_safe(alert.details)
    }
  end

  # --- delivery --------------------------------------------------------------

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
        Logger.warning("alerts: Slack webhook returned #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("alerts: Slack webhook unreachable (#{inspect(reason)})")
        {:error, {:transport, reason}}
    end
  end

  defp client_url(client_id) do
    case Clients.get(client_id) do
      %Client{alerts: %{webhook_url: url}} when is_binary(url) and url != "" -> url
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp any_client_url? do
    Enum.any?(Clients.list(), fn client ->
      present?(client.alerts && client.alerts.webhook_url)
    end)
  catch
    :exit, _reason -> false
  end

  defp icon(%Alert{state: :resolved}), do: ":white_check_mark:"
  defp icon(%Alert{severity: :critical}), do: ":rotating_light:"
  defp icon(%Alert{}), do: ":warning:"

  defp client_name(%Alert{client_name: nil}), do: "monitoring"
  defp client_name(%Alert{client_name: name}), do: name

  defp ratio_label(nil), do: "—"
  defp ratio_label(:infinity), do: "no usual level"
  defp ratio_label(ratio), do: "#{format(ratio)}x"

  defp format(nil), do: "—"
  defp format(:infinity), do: "∞"
  defp format(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 2)
  defp format(number), do: to_string(number)

  # :infinity and structs aren't representable in JSON.
  defp json_safe(details) do
    Map.new(details, fn
      {:ratio, :infinity} -> {:ratio, nil}
      {:mention, mention} -> {:mention_id, mention && mention.id}
      {key, value} when is_float(value) -> {key, Float.round(value, 3)}
      {key, value} -> {key, value}
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
