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
  alias SmmMonitor.Persistence.MentionRecord
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
        conflict_target: [:platform, :mention_id]
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

  @doc "The most recent `limit` mentions for one platform, newest first."
  @spec recent(atom(), pos_integer(), keyword()) :: [Mention.t()]
  def recent(platform, limit, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.platform == ^to_string(platform))
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

  @doc "Rows stored for one platform."
  @spec count(atom(), keyword()) :: non_neg_integer()
  def count(platform, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    MentionRecord
    |> where([m], m.platform == ^to_string(platform))
    |> repo.aggregate(:count)
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end
end
