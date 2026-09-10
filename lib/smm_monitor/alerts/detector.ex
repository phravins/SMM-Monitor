defmodule SmmMonitor.Alerts.Detector do
  @moduledoc """
  Decides whether a burst of negative mentions is worth waking someone for.

  Pure functions over numbers: hand it what was observed and what is
  normal, and it answers. No processes, no clock, no database — which is
  what makes every threshold decision here testable without waiting for a
  real spike.

  ## Why a baseline rather than a threshold

  "Alert at 10 negative mentions an hour" is wrong for every brand at
  once. A client with five mentions a day would never trip it; one with
  five thousand would trip it permanently. So the comparison is against
  *that platform's own recent normal*, drawn from the stored history.

  ## The three guards

  A spike has to clear all three, and each exists to suppress a specific
  kind of false alarm:

    * **Ratio** — negatives must exceed the baseline by a factor
      (3x by default). This is the actual signal.
    * **Floor** — and there must be at least a handful of them (5 by
      default). Without this, going from 0.2 to 2 negative mentions is an
      "infinite spike", and you would be woken for two grumpy posts.
    * **Warm-up** — and there must be enough history to know what normal
      *is* (24h by default). You cannot detect an anomaly without a
      normal, and a fresh install has none: every install's first hour
      would otherwise look like a crisis.
  """

  alias SmmMonitor.Alerts.Alert

  @defaults [
    # Negatives must be this many times the baseline.
    ratio: 3.0,
    # ...and at least this many in absolute terms.
    floor: 5,
    # ...and we must have watched for this long to know what normal is.
    warmup_ms: :timer.hours(24),
    # Above this multiple, it's critical rather than a warning.
    critical_ratio: 6.0
  ]

  @typedoc """
  What was measured.

    * `:observed_negative` — negatives in the current window
    * `:observed_total` — all mentions in the current window
    * `:baseline_negative` — negatives normally expected in a window this
      size, from history
    * `:history_ms` — how much history the baseline was drawn from
  """
  @type observation :: %{
          required(:platform) => atom(),
          required(:window_ms) => pos_integer(),
          required(:observed_negative) => non_neg_integer(),
          required(:baseline_negative) => number() | nil,
          optional(:observed_total) => non_neg_integer(),
          optional(:history_ms) => non_neg_integer()
        }

  @type verdict :: {:alert, Alert.t()} | {:ok, :below_threshold} | {:ok, :warming_up}

  @doc "The detector's default thresholds, overridable via config."
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc "Thresholds in force, from config, falling back to the defaults."
  @spec settings() :: keyword()
  def settings do
    Keyword.merge(@defaults, SmmMonitor.config(:alerts, []))
  end

  @doc """
  Judges one observation.

  Returns `{:alert, alert}`, or `{:ok, reason}` explaining why not — the
  reason is kept rather than collapsed to `false` so the dashboard and
  the logs can say "still warming up" instead of staying silent.
  """
  @spec evaluate(observation(), keyword()) :: verdict()
  def evaluate(observation, opts \\ []) do
    settings = Keyword.merge(settings(), opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      warming_up?(observation, settings) ->
        {:ok, :warming_up}

      observation.observed_negative < settings[:floor] ->
        {:ok, :below_threshold}

      true ->
        judge(observation, settings, now)
    end
  end

  @doc """
  How far above normal an observation is.

  `:infinity` when the baseline is zero and something was observed — a
  brand that has never had a negative mention getting several is a real
  signal, even though the ratio is undefined.

      iex> alias SmmMonitor.Alerts.Detector
      iex> Detector.ratio(12, 2.0)
      6.0
      iex> Detector.ratio(3, 0)
      :infinity
      iex> Detector.ratio(0, 0)
      0.0
  """
  @spec ratio(non_neg_integer(), number() | nil) :: float() | :infinity
  def ratio(observed, baseline)
  def ratio(0, _baseline), do: 0.0
  def ratio(_observed, nil), do: :infinity
  def ratio(_observed, baseline) when baseline <= 0, do: :infinity
  def ratio(observed, baseline), do: observed / baseline

  @doc """
  Scales a rate measured over `history_ms` down to a window of
  `window_ms`, giving the count normally expected in one window.

      iex> alias SmmMonitor.Alerts.Detector
      iex> # 168 negatives over 7 days is 1.0 per hour
      iex> Detector.baseline_for_window(168, :timer.hours(24) * 7, :timer.hours(1))
      1.0
  """
  @spec baseline_for_window(non_neg_integer(), pos_integer(), pos_integer()) :: float()
  def baseline_for_window(_historical_count, history_ms, _window_ms) when history_ms <= 0, do: 0.0

  def baseline_for_window(historical_count, history_ms, window_ms) do
    historical_count * (window_ms / history_ms)
  end

  # --- internals ------------------------------------------------------------

  defp warming_up?(observation, settings) do
    history_ms = Map.get(observation, :history_ms, 0)
    is_nil(observation.baseline_negative) or history_ms < settings[:warmup_ms]
  end

  defp judge(observation, settings, now) do
    ratio = ratio(observation.observed_negative, observation.baseline_negative)

    if above?(ratio, settings[:ratio]) do
      {:alert,
       %Alert{
         platform: observation.platform,
         kind: :negative_spike,
         observed: observation.observed_negative,
         total: Map.get(observation, :observed_total, 0),
         baseline: observation.baseline_negative / 1,
         ratio: ratio,
         severity: severity(ratio, settings[:critical_ratio]),
         window_ms: observation.window_ms,
         at: now
       }}
    else
      {:ok, :below_threshold}
    end
  end

  defp above?(:infinity, _threshold), do: true
  defp above?(ratio, threshold), do: ratio >= threshold

  defp severity(:infinity, _critical), do: :critical
  defp severity(ratio, critical) when ratio >= critical, do: :critical
  defp severity(_ratio, _critical), do: :warning
end
