defmodule SmmMonitor.Persistence do
  @moduledoc """
  Queries over the durable mention log.

  This is the only module that writes SQL. The processing layer talks to
  it, and nothing else needs to know mentions are stored in SQLite at all.

  Every function here is safe to call when the database is unavailable:
  they return `{:error, reason}` or an empty list rather than raising, so
  a broken database degrades the app to what it was before persistence
  existed — an in-memory dashboard — rather than taking it down.
  """

  import Ecto.Query

  require Logger

  alias SmmMonitor.Mention
  alias SmmMonitor.Persistence.{AlertRecord, MentionRecord}
  alias SmmMonitor.Repo

  @doc """
  Stores mentions, ignoring any already present.

  One statement per batch rather than per mention: writes arrive a poll
  at a time, and SQLite is dramatically faster inserting a batch inside a
  single transaction. Conflicts on `(platform, mention_id)` are dropped,
  so re-storing a mention we already have costs nothing and cannot
  duplicate a row.
  """
  @spec store([Mention.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def store(mentions, opts \\ [])

  def store([], _opts), do: {:ok, 0}

  def store(mentions, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    rows = Enum.map(mentions, &MentionRecord.from_mention(&1, now))

    {count, _returning} =
      repo.insert_all(MentionRecord, rows,
        on_conflict: :nothing,
        # Matches the unique index: the same post collected for two
        # clients is two rows, not a conflict.
        conflict_target: [:client_id, :platform, :mention_id]
      )

    {:ok, count}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  The most recent `limit` mentions for each platform, newest first.

  Queried per platform rather than as one global "last N" so a chatty
  platform can't crowd the others out of the restored view.
  """
  @spec recent_by_platform([atom()], pos_integer(), keyword()) :: [Mention.t()]
  def recent_by_platform(platforms, limit, opts \\ []) do
    Enum.flat_map(platforms, &recent(&1, limit, opts))
  end

  @doc """
  The most recent `limit` mentions per platform, for each client.

  The boot load reads this way so a quiet client still gets its history
  back: one global "last N" would hand the whole allowance to whichever
  client is busiest and leave the others' tabs empty after a restart.
  """
  @spec recent_by_client_and_platform([String.t()], [atom()], pos_integer(), keyword()) ::
          [Mention.t()]
  def recent_by_client_and_platform(client_ids, platforms, limit, opts \\ []) do
    Enum.flat_map(client_ids, fn client_id ->
      Enum.flat_map(platforms, &recent(&1, limit, Keyword.put(opts, :client, client_id)))
    end)
  end

  @doc "The most recent `limit` mentions for one platform, newest first."
  @spec recent(atom(), pos_integer(), keyword()) :: [Mention.t()]
  def recent(platform, limit, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.platform == ^to_string(platform))
    |> client_filter(Keyword.get(opts, :client, :all))
    |> order_by([m], desc: m.source_timestamp)
    |> limit(^limit)
    |> repo.all()
    |> Enum.map(&MentionRecord.to_mention/1)
  rescue
    error ->
      Logger.warning("database: could not read #{platform} history (#{inspect(error)})")
      []
  catch
    :exit, reason ->
      Logger.warning("database: could not read #{platform} history (#{inspect(reason)})")
      []
  end

  @doc """
  Deletes mentions published before `cutoff`. Returns how many went.

  Keyed on `source_timestamp`, not `inserted_at`: retention is about how
  old the *mention* is, so backfilling a month of history doesn't earn it
  another 30 days of storage.
  """
  @spec prune(DateTime.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(cutoff, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    {count, _returning} =
      MentionRecord
      |> where([m], m.source_timestamp < ^cutoff)
      |> repo.delete_all()

    {:ok, count}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Counts mentions by sentiment for a platform since `cutoff`.

  This is what the alerting baseline is drawn from: "what does a normal
  hour look like for this platform" can only be answered from stored
  history, since ETS only holds a rolling window.

  Returns `%{positive: n, neutral: n, negative: n, total: n}`, all zero
  if the database is unavailable — an unreadable history means "no
  baseline", which the detector treats as "still warming up" rather than
  as a reason to alert.
  """
  @spec sentiment_counts_since(DateTime.t(), atom(), keyword()) :: %{atom() => non_neg_integer()}
  def sentiment_counts_since(cutoff, platform \\ :all, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    rows =
      MentionRecord
      |> where([m], m.source_timestamp >= ^cutoff)
      |> platform_filter(platform)
      |> client_filter(Keyword.get(opts, :client, :all))
      |> group_by([m], m.sentiment)
      |> select([m], {m.sentiment, count(m.id)})
      |> repo.all()

    counts = Map.new(rows, fn {sentiment, count} -> {sentiment, count} end)

    %{
      positive: Map.get(counts, "positive", 0),
      neutral: Map.get(counts, "neutral", 0),
      negative: Map.get(counts, "negative", 0),
      total: counts |> Map.values() |> Enum.sum()
    }
  rescue
    error ->
      Logger.warning("database: could not read sentiment history (#{inspect(error)})")
      empty_counts()
  catch
    :exit, reason ->
      Logger.warning("database: could not read sentiment history (#{inspect(reason)})")
      empty_counts()
  end

  @doc """
  Records an alert, so it survives the process that raised it.

  Fire and forget: a failed write is logged and swallowed. An alert that
  reached Slack has done its job, and losing its history row is not a
  reason to crash the alerting process.
  """
  @spec store_alert(SmmMonitor.Alerts.Alert.t(), keyword()) :: :ok
  def store_alert(alert, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.insert_all(AlertRecord, [AlertRecord.from_alert(alert)])
    :ok
  rescue
    error ->
      Logger.warning("database: could not record an alert (#{inspect(error)})")
      :ok
  catch
    :exit, reason ->
      Logger.warning("database: could not record an alert (#{inspect(reason)})")
      :ok
  end

  @doc """
  Stored alerts for a client between two timestamps, newest first.

  Returns the rows rather than rebuilt `Alert` structs: a report shows
  the message as it was sent, and re-deriving the wording would make old
  alerts silently change when the phrasing improves.
  """
  @spec alerts_between(DateTime.t(), DateTime.t(), keyword()) :: [AlertRecord.t()]
  def alerts_between(from, to, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    AlertRecord
    |> where([a], a.raised_at >= ^from and a.raised_at <= ^to)
    |> client_filter(Keyword.get(opts, :client, :all))
    |> order_by([a], desc: a.raised_at)
    |> repo.all()
  rescue
    error ->
      Logger.warning("database: could not read alert history (#{inspect(error)})")
      []
  catch
    :exit, reason ->
      Logger.warning("database: could not read alert history (#{inspect(reason)})")
      []
  end

  @doc """
  Whether any alert has ever been recorded.

  What tells a report the difference between "alerting is running and
  nothing happened" and "alerting was never on for this period" — two
  facts that look identical from an empty list.
  """
  @spec any_alerts?(keyword()) :: boolean()
  def any_alerts?(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.aggregate(AlertRecord, :count) > 0
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  Every mention for a client between two timestamps, newest first.

  Used by reporting, which needs the whole period rather than "the most
  recent N" — a report that quietly dropped the oldest day of a week
  would be wrong in a way nobody could see.
  """
  @spec between(DateTime.t(), DateTime.t(), keyword()) :: [Mention.t()]
  def between(from, to, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.source_timestamp >= ^from and m.source_timestamp <= ^to)
    |> platform_filter(Keyword.get(opts, :platform, :all))
    |> client_filter(Keyword.get(opts, :client, :all))
    |> order_by([m], desc: m.source_timestamp)
    |> repo.all()
    |> Enum.map(&MentionRecord.to_mention/1)
  rescue
    error ->
      Logger.warning("database: could not read the report period (#{inspect(error)})")
      []
  catch
    :exit, reason ->
      Logger.warning("database: could not read the report period (#{inspect(reason)})")
      []
  end

  @doc """
  Publication timestamps of a client's mentions since `cutoff`.

  Timestamps alone rather than whole rows: the volume baseline counts
  mentions per hour and needs nothing else, and a week of full rows for
  a busy client is a lot of text to read and discard.
  """
  @spec timestamps_since(DateTime.t(), keyword()) :: [DateTime.t()]
  def timestamps_since(cutoff, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.source_timestamp >= ^cutoff)
    |> platform_filter(Keyword.get(opts, :platform, :all))
    |> client_filter(Keyword.get(opts, :client, :all))
    |> select([m], m.source_timestamp)
    |> repo.all()
  rescue
    error ->
      Logger.warning("database: could not read mention history (#{inspect(error)})")
      []
  catch
    :exit, reason ->
      Logger.warning("database: could not read mention history (#{inspect(reason)})")
      []
  end

  @doc """
  The timestamp of the oldest stored mention, or `nil` when empty.

  Used to work out how much history the baseline actually rests on, so a
  day-old install isn't treated as having a week of normal.
  """
  @spec earliest_timestamp(atom(), keyword()) :: DateTime.t() | nil
  def earliest_timestamp(platform \\ :all, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> platform_filter(platform)
    |> client_filter(Keyword.get(opts, :client, :all))
    |> select([m], min(m.source_timestamp))
    |> repo.one()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc """
  Mention volume and average sentiment per day, for one client.

  Grouped in SQL rather than in Elixir. The trends screen asks for this
  on every refresh, and the alternative — loading a month of mentions to
  count them — reads thousands of rows across the wire to produce thirty
  numbers. Here the database returns one row per day and the work stays
  proportional to the *window*, not to how much history has accumulated
  behind it.

  Days are UTC, and taken from when the mention was published rather
  than when we collected it: that is the day the client would say it
  happened, and it matches what the reports say about the same period.

  Returns only days that have mentions — a caller wanting a gap-free
  series should zero-fill from the period, as `SmmMonitor.Trends` does.
  Rows come back oldest first.
  """
  @spec daily_stats(DateTime.t(), DateTime.t(), keyword()) :: [map()]
  def daily_stats(from, to, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.source_timestamp >= ^from and m.source_timestamp <= ^to)
    |> platform_filter(Keyword.get(opts, :platform, :all))
    |> client_filter(Keyword.get(opts, :client, :all))
    |> group_by([m], fragment("date(?)", m.source_timestamp))
    |> order_by([m], fragment("date(?)", m.source_timestamp))
    |> select([m], %{
      day: fragment("date(?)", m.source_timestamp),
      count: count(m.id),
      # Rows written before scoring became numeric have a null value;
      # avg() skips them, which is right — a guessed score would move
      # the line without anybody having said anything.
      average: avg(m.sentiment_value),
      positive: fragment("sum(case when ? = 'positive' then 1 else 0 end)", m.sentiment),
      negative: fragment("sum(case when ? = 'negative' then 1 else 0 end)", m.sentiment)
    })
    |> repo.all()
    |> Enum.map(&decode_day/1)
  rescue
    error ->
      Logger.warning("database: could not read the daily series (#{inspect(error)})")
      []
  catch
    :exit, reason ->
      Logger.warning("database: could not read the daily series (#{inspect(reason)})")
      []
  end

  # SQLite hands back the grouped day as text and the counts as integers;
  # avg() comes back as a float, or nil for a day whose rows all predate
  # numeric scoring.
  defp decode_day(row) do
    %{
      date: Date.from_iso8601!(row.day),
      count: row.count,
      average: average(row.average),
      positive: row.positive || 0,
      negative: row.negative || 0,
      neutral: row.count - (row.positive || 0) - (row.negative || 0)
    }
  end

  defp average(nil), do: 0.0
  defp average(value) when is_float(value), do: Float.round(value, 3)
  defp average(value), do: value / 1

  defp platform_filter(query, :all), do: query
  defp platform_filter(query, platform), do: where(query, [m], m.platform == ^to_string(platform))

  defp client_filter(query, :all), do: query
  defp client_filter(query, client_id), do: where(query, [m], m.client_id == ^to_string(client_id))

  defp empty_counts, do: %{positive: 0, neutral: 0, negative: 0, total: 0}

  @doc "Total rows stored. Used by tests and the config screen."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.aggregate(MentionRecord, :count)
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end

  @doc "Rows stored for one platform, optionally scoped to one client."
  @spec count(atom(), keyword()) :: non_neg_integer()
  def count(platform, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> platform_filter(platform)
    |> client_filter(Keyword.get(opts, :client, :all))
    |> repo.aggregate(:count)
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end
end
