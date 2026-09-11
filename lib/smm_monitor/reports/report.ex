defmodule SmmMonitor.Reports.Report do
  @moduledoc """
  Everything a client report says, as data.

  Assembled once and then rendered — to PDF, to CSV, to anything else
  later — so the numbers are computed in one place and every format shows
  the same ones. A renderer that did its own arithmetic would eventually
  disagree with its sibling, and nobody would notice until a client did.
  """

  alias SmmMonitor.Reports.Period

  @enforce_keys [:client, :period, :generated_at]
  defstruct [
    :client,
    :period,
    :generated_at,
    total: 0,
    by_platform: %{},
    daily: [],
    average_sentiment: 0.0,
    previous_average: nil,
    previous_total: 0,
    trend: :flat,
    volume_trend: :flat,
    sentiment_split: %{positive: 0, neutral: 0, negative: 0},
    top_positive: [],
    top_negative: [],
    alerts: [],
    alerts_available: false,
    mentions: []
  ]

  @type trend :: :up | :down | :flat

  @type day :: %{
          date: Date.t(),
          count: non_neg_integer(),
          average: float()
        }

  @type t :: %__MODULE__{
          client: SmmMonitor.Client.t(),
          period: Period.t(),
          generated_at: DateTime.t(),
          total: non_neg_integer(),
          by_platform: %{atom() => non_neg_integer()},
          daily: [day()],
          average_sentiment: float(),
          previous_average: float() | nil,
          previous_total: non_neg_integer(),
          trend: trend(),
          volume_trend: trend(),
          sentiment_split: %{atom() => non_neg_integer()},
          top_positive: [SmmMonitor.Mention.t()],
          top_negative: [SmmMonitor.Mention.t()],
          alerts: [map()],
          alerts_available: boolean(),
          mentions: [SmmMonitor.Mention.t()]
        }

  @doc """
  A word for which way sentiment moved, for the report's prose.

  Deliberately plain: a client reading "improving" understands it, where
  "+0.08 delta" needs explaining.
  """
  @spec trend_label(trend()) :: String.t()
  def trend_label(:up), do: "improving"
  def trend_label(:down), do: "declining"
  def trend_label(:flat), do: "steady"

  @doc "An arrow for the same thing, for tables where space is short."
  @spec trend_arrow(trend()) :: String.t()
  def trend_arrow(:up), do: "UP"
  def trend_arrow(:down), do: "DOWN"
  def trend_arrow(:flat), do: "FLAT"

  @doc """
  How the period's sentiment compares with the one before, in words.

  Says "no prior period to compare" rather than inventing a trend when
  there is nothing behind it — a first report claiming "steady" would be
  asserting something it cannot know.
  """
  @spec comparison(t()) :: String.t()
  def comparison(%__MODULE__{previous_average: nil}), do: "no prior period to compare against"

  def comparison(%__MODULE__{} = report) do
    delta = report.average_sentiment - report.previous_average

    "#{trend_label(report.trend)} (#{signed(delta)} against #{format(report.previous_average)} " <>
      "in the #{report.period.days} days before)"
  end

  @doc "A short label for the volume change, for the summary table."
  @spec volume_comparison(t()) :: String.t()
  def volume_comparison(%__MODULE__{previous_total: 0}), do: "no prior period"

  def volume_comparison(%__MODULE__{} = report) do
    change = percentage_change(report.total, report.previous_total)
    "#{signed_percent(change)} vs #{report.previous_total}"
  end

  @doc """
  Percentage change between two counts.

      iex> SmmMonitor.Reports.Report.percentage_change(150, 100)
      50.0
      iex> SmmMonitor.Reports.Report.percentage_change(0, 0)
      0.0
  """
  @spec percentage_change(number(), number()) :: float()
  def percentage_change(_now, 0), do: 0.0
  def percentage_change(now, before), do: Float.round((now - before) / before * 100, 1)

  @doc "Whether there is enough in the period to be worth reporting on."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{total: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  defp signed(number) when number >= 0, do: "+#{format(number)}"
  defp signed(number), do: format(number)

  defp signed_percent(number) when number >= 0, do: "+#{number}%"
  defp signed_percent(number), do: "#{number}%"

  defp format(number), do: :erlang.float_to_binary(number / 1, decimals: 2)
end
