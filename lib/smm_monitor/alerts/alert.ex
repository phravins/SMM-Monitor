defmodule SmmMonitor.Alerts.Alert do
  @moduledoc """
  A raised alert: whose brand, what happened, and the numbers behind it.

  Carries the evidence rather than just a message, so a notifier can
  render it however its channel wants and the dashboard can show the
  numbers instead of asking someone to trust an adjective.

  ## Firing and resolved are the same struct

  An alert is raised when a condition starts being true and again when
  it stops, and the two share a shape so a notifier renders both without
  a second code path. `state` says which, and a resolved alert carries
  `opened_at` so the message can say how long it went on — which is the
  first thing anyone asks.
  """

  @enforce_keys [:kind, :at]
  defstruct [
    :kind,
    # Which client's brand. Alerts land in a shared channel, so this is
    # in the first line of every message rather than looked up after.
    :client_id,
    :client_name,
    # What within the kind: the watch phrase that matched. `nil` for the
    # conditions that can only happen once per client at a time.
    :subject,
    :severity,
    :window_ms,
    :at,
    # When the incident opened. Equal to `at` while firing; earlier than
    # it once resolved.
    :opened_at,
    # Condition-specific numbers, rendered by `message/1`.
    details: %{},
    state: :firing
  ]

  @type severity :: :warning | :critical
  @type state :: :firing | :resolved

  @type t :: %__MODULE__{
          kind: atom(),
          client_id: String.t() | nil,
          client_name: String.t() | nil,
          subject: String.t() | nil,
          severity: severity(),
          window_ms: pos_integer() | nil,
          at: DateTime.t(),
          opened_at: DateTime.t() | nil,
          details: map(),
          state: state()
        }

  @doc """
  A one-line human summary, used by every notifier and the dashboard.

      iex> alias SmmMonitor.Alerts.Alert
      iex> alert = %Alert{kind: :sentiment_drop, client_name: "Acme", state: :firing,
      ...>   window_ms: 3_600_000, at: ~U[2026-09-12 12:00:00Z],
      ...>   details: %{observed: -0.42, threshold: -0.3, count: 24}}
      iex> Alert.message(alert)
      "Acme: sentiment fell to -0.42 over 24 mentions in the last 1h (threshold -0.3)"
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{state: :resolved} = alert), do: resolved_message(alert)
  def message(%__MODULE__{} = alert), do: "#{client_label(alert)}: #{firing_body(alert)}"

  @doc "A compact label for the dashboard's banner, where space is scarce."
  @spec short(t()) :: String.t()
  def short(%__MODULE__{kind: :sentiment_drop, details: details}) do
    "sentiment #{format(details[:observed])} over #{details[:count]} mentions"
  end

  def short(%__MODULE__{kind: :volume_spike, details: details}) do
    "#{details[:observed]} mentions (#{ratio_label(details[:ratio])} normal)"
  end

  def short(%__MODULE__{kind: :watch_phrase, subject: phrase, details: details}) do
    "\"#{phrase}\" in #{details[:observed]} mention(s)"
  end

  def short(%__MODULE__{kind: kind}), do: to_string(kind)

  @doc """
  Key used to tell one ongoing incident from another.

  Scoped by client so one client's spike can't silence another's, and by
  subject so two different watch phrases are two different problems.
  """
  @spec key(t()) :: {String.t() | nil, atom(), String.t() | nil}
  def key(%__MODULE__{client_id: client_id, kind: kind, subject: subject}) do
    {client_id, kind, subject}
  end

  @doc "A human name for a kind, for the config screen and the docs."
  @spec kind_label(atom()) :: String.t()
  def kind_label(:sentiment_drop), do: "sentiment"
  def kind_label(:volume_spike), do: "volume"
  def kind_label(:watch_phrase), do: "watch phrase"
  def kind_label(kind), do: kind |> to_string() |> String.replace("_", " ")

  @doc "Builds a firing alert from a condition's details."
  @spec firing(map(), map(), keyword()) :: t()
  def firing(details, client, opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    %__MODULE__{
      kind: Map.fetch!(details, :kind),
      client_id: client[:id],
      client_name: client[:name],
      subject: Map.get(details, :phrase),
      severity: Map.get(details, :severity, :warning),
      window_ms: Keyword.get(opts, :window_ms),
      at: at,
      opened_at: at,
      details: Map.drop(details, [:kind, :severity, :phrase]),
      state: :firing
    }
  end

  @doc """
  The resolved counterpart of a firing alert.

  Keeps the original's numbers so the resolution can say what it was
  that ended, and takes the recovery's own numbers where there are any.
  """
  @spec resolved(t(), map(), DateTime.t()) :: t()
  def resolved(%__MODULE__{} = alert, recovery_details, at) do
    %{
      alert
      | state: :resolved,
        at: at,
        severity: :warning,
        details: Map.merge(alert.details, recovery_details)
    }
  end

  @doc "How long the incident ran, in milliseconds."
  @spec duration_ms(t()) :: non_neg_integer()
  def duration_ms(%__MODULE__{opened_at: nil}), do: 0

  def duration_ms(%__MODULE__{opened_at: opened_at, at: at}) do
    at |> DateTime.diff(opened_at, :millisecond) |> max(0)
  end

  @doc """
  Window length as a short label.

      iex> SmmMonitor.Alerts.Alert.window_label(3_600_000)
      "1h"
  """
  @spec window_label(pos_integer() | nil) :: String.t()
  def window_label(nil), do: "the window"

  def window_label(ms) do
    cond do
      ms >= :timer.hours(1) -> "#{div(ms, :timer.hours(1))}h"
      ms >= :timer.minutes(1) -> "#{div(ms, :timer.minutes(1))}m"
      true -> "#{div(ms, 1_000)}s"
    end
  end

  # --- internals ------------------------------------------------------------

  defp client_label(%__MODULE__{client_name: nil}), do: "monitoring"
  defp client_label(%__MODULE__{client_name: name}), do: name

  defp firing_body(%__MODULE__{kind: :sentiment_drop, details: details} = alert) do
    "sentiment fell to #{format(details[:observed])} over #{details[:count]} mentions " <>
      "in the last #{window_label(alert.window_ms)} (threshold #{format(details[:threshold])})"
  end

  defp firing_body(%__MODULE__{kind: :volume_spike, details: details} = alert) do
    "#{details[:observed]} mentions in the last #{window_label(alert.window_ms)}, " <>
      "#{ratio_label(details[:ratio])} the usual #{format(details[:baseline])} " <>
      "for this hour"
  end

  defp firing_body(%__MODULE__{kind: :watch_phrase, subject: phrase, details: details} = alert) do
    "\"#{phrase}\" mentioned #{occurrences(details[:observed])} in the last " <>
      "#{window_label(alert.window_ms)} — #{inspect(details[:excerpt])}"
  end

  defp firing_body(%__MODULE__{kind: kind}), do: to_string(kind)

  defp resolved_message(%__MODULE__{} = alert) do
    "#{client_label(alert)}: #{resolved_body(alert)} (#{duration_label(duration_ms(alert))})"
  end

  defp resolved_body(%__MODULE__{kind: :sentiment_drop, details: details}) do
    "sentiment recovered to #{format(details[:observed])}"
  end

  defp resolved_body(%__MODULE__{kind: :volume_spike, details: details}) do
    "mention volume back to normal at #{details[:observed]}"
  end

  defp resolved_body(%__MODULE__{kind: :watch_phrase, subject: phrase}) do
    "\"#{phrase}\" no longer being mentioned"
  end

  defp resolved_body(%__MODULE__{kind: kind}), do: "#{kind} cleared"

  defp occurrences(1), do: "once"
  defp occurrences(count), do: "#{count} times"

  defp duration_label(ms) when ms < 60_000, do: "lasted under a minute"
  defp duration_label(ms) when ms < 3_600_000, do: "lasted #{div(ms, 60_000)} min"

  defp duration_label(ms) do
    hours = Float.round(ms / 3_600_000, 1)
    "lasted #{hours}h"
  end

  defp ratio_label(nil), do: "far above"
  defp ratio_label(:infinity), do: "far above"
  defp ratio_label(ratio), do: "#{format(ratio)}x"

  defp format(nil), do: "?"
  defp format(:infinity), do: "∞"
  defp format(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 2)
  defp format(number), do: to_string(number)
end
