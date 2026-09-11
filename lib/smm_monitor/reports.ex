defmodule SmmMonitor.Reports do
  @moduledoc """
  Builds a client report from stored history.

  What a client is actually handed at the end of a week: how much was
  said, whether it was getting better or worse, the posts worth reading,
  and anything that raised an alarm.

  ## Read from disk, not from ETS

  ETS holds a rolling window measured in hours. A report covers days or
  weeks, so every number here comes from the durable log — which also
  means a report is reproducible: running it twice for the same period
  gives the same answer, and running it after a restart still works.

  ## Comparison is the point

  "412 mentions" says nothing on its own. Every headline figure is
  computed for the period *and* the one before it, of exactly the same
  length, so the report can say "up from 280" and mean it. A first
  report with no history behind it says so rather than inventing a
  trend.
  """

  alias SmmMonitor.Reports.{PDF, Period, Report, Writer}
  alias SmmMonitor.{Client, Clients, Mention, Persistence}

  # Enough to read over coffee; more than this and nobody reads any.
  @top_mentions 5

  # Sentiment has to move by more than this to count as a change of
  # direction rather than noise. Two weeks of ordinary chatter differ by
  # a few hundredths without anything having happened.
  @trend_threshold 0.05

  # Volume has to move by more than this share to count as a direction.
  @volume_trend_threshold 0.10

  @doc """
  Builds the report for a client over a period.

  Returns `{:error, :unknown_client}` rather than an empty report for an
  id that doesn't exist: a report about nobody is not a useful artefact,
  and silently producing one would let a typo reach a client.
  """
  @spec build(String.t() | Client.t(), Period.t(), keyword()) ::
          {:ok, Report.t()} | {:error, :unknown_client}
  def build(client_or_id, period, opts \\ [])

  def build(%Client{} = client, %Period{} = period, opts) do
    mentions = Persistence.between(period.from, period.to, client: client.id)
    previous = Period.previous(period)
    previous_mentions = Persistence.between(previous.from, previous.to, client: client.id)

    previous_average = average_sentiment(previous_mentions)
    average = average_sentiment(mentions)

    {:ok,
     %Report{
       client: client,
       period: period,
       generated_at: Keyword.get(opts, :now, DateTime.utc_now()),
       total: length(mentions),
       by_platform: by_platform(mentions),
       daily: daily(mentions, period),
       average_sentiment: average || 0.0,
       previous_average: previous_average,
       previous_total: length(previous_mentions),
       trend: trend(average, previous_average),
       volume_trend: volume_trend(length(mentions), length(previous_mentions)),
       sentiment_split: sentiment_split(mentions),
       top_positive: top_positive(mentions),
       top_negative: top_negative(mentions),
       alerts: alerts_for(client, period, opts),
       alerts_available: alerts_available?(opts),
       mentions: mentions
     }}
  end

  def build(client_id, %Period{} = period, opts) when is_binary(client_id) do
    case lookup(client_id, opts) do
      nil -> {:error, :unknown_client}
      client -> build(client, period, opts)
    end
  end

  @doc """
  Builds a client's report and writes it to disk.

  The whole job in one call, for the callers that want the files rather
  than the numbers: the dashboard's `R` key, the weekly schedule, and a
  release, where there is no `mix` to run:

      bin/smm_monitor rpc 'SmmMonitor.Reports.generate("acme-corp", days: 7)'

  Takes `:days` (default 7) or a `:period`, and `:formats` (default:
  whatever this machine can produce). Returns `{:ok, paths}`.
  """
  @spec generate(String.t() | Client.t(), keyword()) :: {:ok, [Path.t()]} | {:error, term()}
  def generate(client_or_id, opts \\ []) do
    period =
      Keyword.get_lazy(opts, :period, fn -> Period.last_days(Keyword.get(opts, :days, 7)) end)

    formats = Keyword.get_lazy(opts, :formats, &available_formats/0)

    with {:ok, report} <- build(client_or_id, period, opts) do
      Writer.write(report, formats, opts)
    end
  end

  @doc """
  The formats this machine can actually produce.

  PDF when the Python toolchain is there, CSV always: a server without
  it should still get its data, rather than nothing at all. The `mix`
  task deliberately doesn't use this — someone at a terminal asking for
  a PDF wants to be told what to install, not quietly handed a CSV.
  """
  @spec available_formats() :: [:pdf | :csv]
  def available_formats do
    case PDF.available() do
      :ok -> [:pdf, :csv]
      {:error, _reason} -> [:csv]
    end
  end

  @doc "Every active client, for the scheduled run."
  @spec active_clients(keyword()) :: [Client.t()]
  def active_clients(opts \\ []) do
    case Keyword.get(opts, :clients) do
      nil -> safe_clients(&Clients.active/0)
      clients -> Enum.filter(clients, & &1.active)
    end
  end

  @doc "How many top mentions each direction gets."
  @spec top_count() :: pos_integer()
  def top_count, do: @top_mentions

  # --- internals ------------------------------------------------------------

  defp lookup(client_id, opts) do
    case Keyword.get(opts, :clients) do
      nil -> safe_get(client_id)
      clients -> Enum.find(clients, &(&1.id == client_id))
    end
  end

  defp safe_get(client_id) do
    Clients.get(client_id)
  catch
    :exit, _reason -> nil
  end

  defp safe_clients(fun) do
    fun.()
  catch
    :exit, _reason -> []
  end

  defp by_platform(mentions) do
    # Every configured platform appears, including the ones with nothing
    # in them: "instagram 0" is information, a missing row is a question.
    counts = Enum.frequencies_by(mentions, & &1.platform)
    Map.new(SmmMonitor.platforms(), &{&1, Map.get(counts, &1, 0)})
  end

  defp daily(mentions, period) do
    by_date = Enum.group_by(mentions, &(&1.timestamp |> DateTime.to_date()))

    # Driven by the period's dates rather than by the data, so a silent
    # day is a zero in the series instead of a gap in the chart.
    Enum.map(Period.dates(period), fn date ->
      day_mentions = Map.get(by_date, date, [])

      %{
        date: date,
        count: length(day_mentions),
        average: average_sentiment(day_mentions) || 0.0
      }
    end)
  end

  defp sentiment_split(mentions) do
    counts = Enum.frequencies_by(mentions, & &1.sentiment)

    Map.new([:positive, :neutral, :negative], &{&1, Map.get(counts, &1, 0)})
  end

  # nil rather than 0.0 for an empty period: "no mentions" and "mentions
  # averaging exactly neutral" are different facts, and the trend must
  # not treat the first as evidence.
  defp average_sentiment([]), do: nil

  defp average_sentiment(mentions) do
    mentions
    |> Enum.map(& &1.sentiment_value)
    |> Enum.sum()
    |> Kernel./(length(mentions))
    |> Float.round(3)
  end

  defp top_positive(mentions) do
    mentions
    |> Enum.filter(&(&1.sentiment_value > 0))
    |> Enum.sort_by(&{-&1.sentiment_value, &1.timestamp}, :asc)
    |> Enum.take(@top_mentions)
  end

  defp top_negative(mentions) do
    mentions
    |> Enum.filter(&(&1.sentiment_value < 0))
    |> Enum.sort_by(&{&1.sentiment_value, &1.timestamp}, :asc)
    |> Enum.take(@top_mentions)
  end

  defp trend(_average, nil), do: :flat
  defp trend(nil, _previous), do: :flat

  defp trend(average, previous) do
    cond do
      average - previous > @trend_threshold -> :up
      previous - average > @trend_threshold -> :down
      true -> :flat
    end
  end

  defp volume_trend(_total, 0), do: :flat

  defp volume_trend(total, previous) do
    change = (total - previous) / previous

    cond do
      change > @volume_trend_threshold -> :up
      change < -@volume_trend_threshold -> :down
      true -> :flat
    end
  end

  # Alerting is a separate feature and may not have been running for the
  # period — switched off, or an install that predates it. A report has
  # to tell "nothing happened" apart from "nothing was watching", so the
  # section is skipped with a note rather than silently left empty.
  defp alerts_available?(opts) do
    case Keyword.fetch(opts, :alerts) do
      {:ok, _alerts} -> true
      :error -> Persistence.any_alerts?()
    end
  end

  # Read from the durable log rather than from the alerting process:
  # a report is usually generated from a separate `mix` invocation,
  # where that process holds no history at all.
  defp alerts_for(%Client{id: client_id}, period, opts) do
    case Keyword.fetch(opts, :alerts) do
      {:ok, alerts} ->
        alerts
        |> Enum.filter(&Period.covers?(period, &1.at))
        |> Enum.sort_by(& &1.at, {:desc, DateTime})

      :error ->
        Persistence.alerts_between(period.from, period.to, client: client_id)
    end
  end

  @doc """
  A one-line summary of a mention, for a report table.

  Long posts are trimmed: a report is meant to be read, and a single
  rambling mention should not take a page.
  """
  @spec excerpt(Mention.t(), pos_integer()) :: String.t()
  def excerpt(mention, max \\ 400)

  def excerpt(%Mention{text: nil}, _max), do: ""

  def excerpt(%Mention{text: text}, max) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
