defmodule SmmMonitor.Monitor do
  @moduledoc """
  Public API over the processing layer.

  Fetchers write through `record/1`; the TUI reads through `stats/3`,
  `recent/3` and `breakdown/2`. Nothing outside this module should need to
  know that mentions live in ETS or that a GenServer owns the table — which
  is what makes the storage swappable later.

  ## Client scope

  Every read takes a client id, or `:all` to read across the whole book.
  The dashboard always passes the selected client: "all platforms" means
  all of *this client's* platforms, never every client mixed together,
  which would be a number nobody could act on.
  """

  alias SmmMonitor.Mention
  alias SmmMonitor.Processing.{Processor, Store}

  @type window :: pos_integer() | :all

  @type client_scope :: String.t() | :all

  @type stats :: %{
          platform: atom(),
          client: client_scope(),
          count: non_neg_integer(),
          positive: non_neg_integer(),
          neutral: non_neg_integer(),
          negative: non_neg_integer(),
          # Sum of the raw lexicon scores, kept for continuity.
          score: integer(),
          # Sum of the normalised -1.0..1.0 scores, and their mean.
          value: float(),
          average: float(),
          window_ms: window()
        }

  @doc "Records one mention (a `Mention` struct or a plain attrs map)."
  @spec record(Mention.t() | map()) :: {:ok, map()}
  def record(mention), do: record_many([mention])

  @doc "Records a batch of mentions in a single call."
  @spec record_many([Mention.t() | map()]) :: {:ok, map()}
  def record_many(mentions), do: Processor.ingest(mentions)

  @doc """
  Aggregate counts and sentiment for a platform over a time window.

  `platform` is `:all` or a platform atom; `window` is a duration in
  milliseconds (defaults to the configured `:window_ms`) or `:all`.
  """
  @spec stats(atom(), window(), client_scope()) :: stats()
  def stats(platform \\ :all, window \\ nil, client \\ :all) do
    window = window || SmmMonitor.config(:window_ms, :timer.hours(24))
    mentions = Store.all(table(), platform, since: since(window), client: client)

    empty = %{positive: 0, neutral: 0, negative: 0, score: 0, value: 0.0}

    tally =
      Enum.reduce(mentions, empty, fn mention, acc ->
        acc
        |> Map.update!(mention.sentiment, &(&1 + 1))
        |> Map.update!(:score, &(&1 + mention.sentiment_score))
        |> Map.update!(:value, &(&1 + mention.sentiment_value))
      end)

    count = length(mentions)

    tally
    |> Map.put(:platform, platform)
    |> Map.put(:client, client)
    |> Map.put(:count, count)
    |> Map.put(:average, average(tally.value, count))
    |> Map.put(:window_ms, window)
  end

  # The mean normalised score, which is what the dashboard reports. A sum
  # would grow with volume and say nothing about how people feel; the mean
  # stays comparable between a quiet platform and a busy one.
  defp average(_value, 0), do: 0.0
  defp average(value, count), do: Float.round(value / count, 2)

  @doc """
  Mention counts per platform over a window, for the tab bar.

  Always includes every configured platform, so a quiet platform shows `0`
  rather than disappearing from the UI.
  """
  @spec breakdown(window(), client_scope()) :: %{atom() => non_neg_integer()}
  def breakdown(window \\ nil, client \\ :all) do
    window = window || SmmMonitor.config(:window_ms, :timer.hours(24))
    since = since(window)

    Map.new(SmmMonitor.platforms(), fn platform ->
      {platform, Store.count(table(), platform, since: since, client: client)}
    end)
  end

  @doc "Most recent mentions for a platform and client, newest first."
  @spec recent(atom(), pos_integer(), client_scope()) :: [Mention.t()]
  def recent(platform \\ :all, limit \\ 100, client \\ :all) do
    Store.recent(table(), platform,
      limit: limit,
      since: since(SmmMonitor.config(:window_ms, :timer.hours(24))),
      client: client
    )
  end

  @doc "Lifetime ingest totals per platform, including mentions since pruned."
  @spec totals() :: %{atom() => non_neg_integer()}
  def totals, do: Processor.totals()

  @doc "Drops all stored mentions. Test helper."
  @spec reset() :: :ok
  def reset, do: Processor.reset()

  # Reads go straight to the named table; falling back to a GenServer call
  # only if a test started the processor with a different table name.
  defp table do
    case :ets.whereis(Store.table_name()) do
      :undefined -> Processor.table()
      table -> table
    end
  end

  defp since(:all), do: 0

  defp since(window_ms) when is_integer(window_ms) do
    DateTime.utc_now()
    |> DateTime.add(-window_ms, :millisecond)
    |> DateTime.to_unix(:millisecond)
  end
end
