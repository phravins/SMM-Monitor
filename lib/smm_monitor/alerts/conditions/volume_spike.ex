defmodule SmmMonitor.Alerts.Conditions.VolumeSpike do
  @moduledoc """
  Alerts when a client's mention volume reaches a multiple of their own
  normal for this hour.

  A **relative** measure: twenty mentions is a story for a quiet brand
  and a Tuesday for a loud one, so the comparison is always against that
  client's own baseline rather than a number someone picked. See
  `SmmMonitor.Alerts.Baseline` for why "normal" is the same hour on
  previous days rather than a flat average.

  ## Two guards, and why each exists

    * **A floor.** Going from 0.2 mentions an hour to 2 is a tenfold
      spike and means nothing. Without a floor, the quietest clients
      alert the most, which is exactly backwards.
    * **A warm-up.** You cannot detect an anomaly without a normal, and a
      client added this morning has none. Every new client's first day
      would otherwise be one long spike.

  ## This is not a bad-news alert

  A volume spike says *something is happening*, not *something is
  wrong* — a product launch and a data breach look identical here. The
  sentiment condition is what separates them, and the alert body carries
  the window's sentiment so the reader can tell at a glance which one
  this is.
  """

  alias SmmMonitor.Alerts.{Baseline, Conditions}
  alias SmmMonitor.Client.AlertConfig

  # Enough days with mentions in this hour to call the average a normal.
  @min_days_observed 2

  @typedoc """
  What was measured.

    * `:count` — mentions in the current window
    * `:baseline` — a `Baseline.t()` for the same hour on previous days
    * `:average_sentiment` — the window's mean sentiment, for context
  """
  @type observation :: %{
          required(:count) => non_neg_integer(),
          required(:baseline) => Baseline.t(),
          optional(:average_sentiment) => float()
        }

  @doc "The kind this condition raises."
  @spec kind() :: atom()
  def kind, do: :volume_spike

  @doc "How many days of same-hour history are needed before alerting."
  @spec min_days_observed() :: pos_integer()
  def min_days_observed, do: @min_days_observed

  @doc """
  Judges one window's volume against the baseline.

      iex> alias SmmMonitor.Alerts.Conditions.VolumeSpike
      iex> alias SmmMonitor.Client.AlertConfig
      iex> baseline = %{average: 4.0, days_observed: 7, samples: [4, 4, 4, 4, 4, 4, 4]}
      iex> VolumeSpike.evaluate(%{count: 30, baseline: baseline}, AlertConfig.new())
      ...> |> elem(0)
      :alert
      iex> VolumeSpike.evaluate(%{count: 8, baseline: baseline}, AlertConfig.new())
      {:ok, :below_threshold}
  """
  @spec evaluate(observation(), AlertConfig.t()) :: Conditions.verdict()
  def evaluate(observation, %AlertConfig{} = config) do
    baseline = observation.baseline
    ratio = Baseline.ratio(observation.count, baseline.average)

    cond do
      baseline.days_observed < @min_days_observed ->
        {:ok, :warming_up}

      observation.count < config.volume_floor ->
        {:ok, :below_threshold}

      above?(ratio, config.volume_multiple) ->
        {:alert,
         %{
           kind: kind(),
           observed: observation.count,
           baseline: baseline.average,
           ratio: ratio,
           days_observed: baseline.days_observed,
           average_sentiment: Map.get(observation, :average_sentiment, 0.0),
           severity: severity(ratio, config.volume_multiple)
         }}

      true ->
        {:ok, :below_threshold}
    end
  end

  @doc """
  Whether the spike is over.

  Cleared at 80% of the trigger multiple rather than at the multiple
  itself: volume hovering either side of the line would otherwise alert
  and resolve every minute for as long as the story ran.
  """
  @spec cleared?(observation(), AlertConfig.t()) :: boolean()
  def cleared?(observation, %AlertConfig{} = config) do
    ratio = Baseline.ratio(observation.count, observation.baseline.average)

    observation.count < config.volume_floor or
      not above?(ratio, config.volume_multiple * 0.8)
  end

  defp above?(:infinity, _multiple), do: true
  defp above?(ratio, multiple), do: ratio >= multiple

  defp severity(:infinity, _multiple), do: :critical
  defp severity(ratio, multiple) when ratio >= multiple * 2, do: :critical
  defp severity(_ratio, _multiple), do: :warning
end
