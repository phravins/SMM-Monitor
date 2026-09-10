defmodule SmmMonitor.Alerts.Alert do
  @moduledoc """
  A raised alert: what was seen, what was normal, and how far apart they were.

  Carries the numbers rather than just a message, so a notifier can render
  it however its channel wants and the dashboard can show the evidence
  instead of asking someone to trust an adjective.
  """

  @enforce_keys [:platform, :kind, :observed, :baseline, :window_ms, :at]
  defstruct [
    :platform,
    # :negative_spike for now; the shape allows others later.
    :kind,
    :observed,
    :baseline,
    :ratio,
    :severity,
    :window_ms,
    :at,
    total: 0
  ]

  @type severity :: :warning | :critical

  @type t :: %__MODULE__{
          platform: atom(),
          kind: atom(),
          observed: non_neg_integer(),
          baseline: float(),
          ratio: float() | :infinity,
          severity: severity(),
          window_ms: pos_integer(),
          at: DateTime.t(),
          total: non_neg_integer()
        }

  @doc """
  A one-line human summary, used by every notifier and the dashboard.

      iex> alias SmmMonitor.Alerts.Alert
      iex> alert = %Alert{platform: :reddit, kind: :negative_spike, observed: 12,
      ...>   baseline: 2.0, ratio: 6.0, severity: :critical, total: 20,
      ...>   window_ms: 3_600_000, at: ~U[2026-09-10 12:00:00Z]}
      iex> Alert.message(alert)
      "reddit: 12 negative mentions in the last 1h (normally about 2.0) — 6.0x above baseline"
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = alert) do
    "#{alert.platform}: #{alert.observed} negative mentions in the last " <>
      "#{window_label(alert.window_ms)} (normally about #{format(alert.baseline)}) — " <>
      "#{ratio_label(alert.ratio)} above baseline"
  end

  @doc "Key used to rate-limit repeat alerts for the same condition."
  @spec key(t()) :: {atom(), atom()}
  def key(%__MODULE__{platform: platform, kind: kind}), do: {platform, kind}

  @doc "Compact label for the dashboard's banner, where space is scarce."
  @spec short(t()) :: String.t()
  def short(%__MODULE__{} = alert) do
    "#{alert.platform} #{alert.observed} negative (#{ratio_label(alert.ratio)} normal)"
  end

  defp ratio_label(:infinity), do: "far"
  defp ratio_label(ratio), do: "#{format(ratio)}x"

  defp format(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 1)
  defp format(number), do: to_string(number)

  defp window_label(ms) do
    cond do
      ms >= :timer.hours(1) -> "#{div(ms, :timer.hours(1))}h"
      ms >= :timer.minutes(1) -> "#{div(ms, :timer.minutes(1))}m"
      true -> "#{div(ms, 1_000)}s"
    end
  end
end
