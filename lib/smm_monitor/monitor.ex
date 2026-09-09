defmodule SmmMonitor.Monitor do
  @moduledoc """
  Public API over the processing layer.

  Fetchers write through `record/1`; the TUI reads through `stats/2`,
  `recent/2` and `breakdown/1`. Nothing outside this module should need to
  know that mentions live in ETS or that a GenServer owns the table — which
  is what makes the storage swappable later.
  """

  alias SmmMonitor.Mention
  alias SmmMonitor.Processing.{Processor, Store}

  @type window :: pos_integer() | :all

  @type stats :: %{
          platform: atom(),
          count: non_neg_integer(),
          positive: non_neg_integer(),
          neutral: non_neg_integer(),
          negative: non_neg_integer(),
          score: integer(),
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
  @spec stats(atom(), window()) :: stats()
  def stats(platform \\ :all, window \\ nil) do
    window = window || SmmMonitor.config(:window_ms, :timer.hours(24))
    mentions = Store.all(table(), platform, since(window))

    tally =
      Enum.reduce(mentions, %{positive: 0, neutral: 0, negative: 0, score: 0}, fn mention, acc ->
        acc
        |> Map.update!(mention.sentiment, &(&1 + 1))
        |> Map.update!(:score, &(&1 + mention.sentiment_score))
      end)

    tally
    |> Map.put(:platform, platform)
    |> Map.put(:count, length(mentions))
    |> Map.put(:window_ms, window)
  end

  @doc """
  Mention counts per platform over a window, for the tab bar.

  Always includes every configured platform, so a quiet platform shows `0`
  rather than disappearing from the UI.
  """
  @spec breakdown(window()) :: %{atom() => non_neg_integer()}
  def breakdown(window \\ nil) do
    window = window || SmmMonitor.config(:window_ms, :timer.hours(24))
    since = since(window)

    Map.new(SmmMonitor.platforms(), fn platform ->
      {platform, Store.count(table(), platform, since)}
    end)
  end

  @doc "Most recent mentions for a platform, newest first."
  @spec recent(atom(), pos_integer()) :: [Mention.t()]
  def recent(platform \\ :all, limit \\ 100) do
    Store.recent(table(), platform,
      limit: limit,
      since: since(SmmMonitor.config(:window_ms, :timer.hours(24)))
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
