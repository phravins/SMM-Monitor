defmodule SmmMonitor.Alerts.Conditions.SentimentThreshold do
  @moduledoc """
  Alerts when a client's mean sentiment falls to or below their
  threshold.

  An **absolute** measure, unlike the volume condition next door: it
  answers "are people unhappy?" rather than "are they unhappier than
  usual?". Both matter, and a brand that is *reliably* disliked would
  never trip a relative test — its baseline is already bad.

  ## Why a minimum sample

  Three mentions averaging -0.4 is two annoyed customers and a neutral
  one. Averaging over a handful of mentions produces a number that swings
  wildly on one more post, so the condition holds off until there are
  `sentiment_min_mentions` of them. That is the single biggest source of
  false alarms this condition would otherwise have.
  """

  alias SmmMonitor.Alerts.Conditions
  alias SmmMonitor.Client.AlertConfig

  @typedoc """
  What was measured over the window.

    * `:average` — mean normalised sentiment, -1.0..1.0
    * `:count` — how many mentions that average is over
    * `:negative` — how many of them were negative, for the message
  """
  @type observation :: %{
          required(:average) => float(),
          required(:count) => non_neg_integer(),
          optional(:negative) => non_neg_integer()
        }

  @doc "The kind this condition raises."
  @spec kind() :: atom()
  def kind, do: :sentiment_drop

  @doc """
  Judges one window's sentiment.

      iex> alias SmmMonitor.Alerts.Conditions.SentimentThreshold
      iex> alias SmmMonitor.Client.AlertConfig
      iex> config = AlertConfig.new()
      iex> SentimentThreshold.evaluate(%{average: -0.6, count: 20}, config)
      ...> |> elem(0)
      :alert
      iex> SentimentThreshold.evaluate(%{average: -0.6, count: 2}, config)
      {:ok, :too_few_mentions}
      iex> SentimentThreshold.evaluate(%{average: 0.2, count: 20}, config)
      {:ok, :below_threshold}
  """
  @spec evaluate(observation(), AlertConfig.t()) :: Conditions.verdict()
  def evaluate(observation, %AlertConfig{} = config) do
    cond do
      observation.count < config.sentiment_min_mentions ->
        {:ok, :too_few_mentions}

      observation.average <= config.sentiment_threshold ->
        {:alert,
         %{
           kind: kind(),
           observed: observation.average,
           threshold: config.sentiment_threshold,
           count: observation.count,
           negative: Map.get(observation, :negative, 0),
           severity: severity(observation.average, config.sentiment_threshold)
         }}

      true ->
        {:ok, :below_threshold}
    end
  end

  @doc """
  Whether the condition has cleared, used to resolve an open incident.

  Deliberately *not* the negation of `evaluate/2`: an incident clears
  only once sentiment has recovered past the threshold with a margin.
  Without the margin, an average sitting exactly on the threshold would
  alert and resolve alternately for as long as it stayed there.
  """
  @spec cleared?(observation(), AlertConfig.t()) :: boolean()
  def cleared?(observation, %AlertConfig{} = config) do
    observation.count < config.sentiment_min_mentions or
      observation.average > config.sentiment_threshold + hysteresis()
  end

  @doc "How far past the threshold sentiment must recover to count as clear."
  @spec hysteresis() :: float()
  def hysteresis, do: 0.05

  # Twice as far past the threshold as the threshold is from neutral
  # reads as a different order of problem.
  defp severity(average, threshold) when average <= threshold * 2, do: :critical
  defp severity(_average, _threshold), do: :warning
end
