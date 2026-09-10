defmodule SmmMonitor.Fetchers.Instagram.Sources do
  @moduledoc """
  What Instagram will and won't let you monitor, encoded as data.

  Every other platform here answers one question — "who mentioned us
  anywhere?" — with one endpoint. Instagram has no such endpoint, and
  pretending otherwise would be the single most misleading thing this
  codebase could do. So the capability is expressed as a list of narrow
  sources, each with its own scope and its own limits, and the operator
  chooses which ones their permissions actually cover.

  ## The sources

    * `:tags` — media where the business account was **@-tagged by
      someone else**. The closest thing to inbound brand mentions that
      can be *polled*. Needs `instagram_basic`,
      `instagram_manage_comments` and `pages_read_engagement`.

    * `:comments` — comments left on the account's **own** media. Where
      complaints actually land, and cheap to read. Costs one request to
      list recent media plus one per media item, so it is bounded by
      `:media_limit`.

    * `:hashtag` — public media carrying a tracked hashtag, via
      `ig_hashtag_search` then `recent_media`. The only source that sees
      posts from accounts with no relationship to yours, and the one with
      the sharpest limits: **30 unique hashtags per 7 days**, a 24-hour
      window, and **no author** — Meta strips usernames from hashtag
      results, so these arrive attributed to the hashtag itself.

  ## What no source covers

  An @-mention of the brand in someone else's caption or comment, where
  the account was not tagged in the media, is delivered **only by
  webhook** — a push to a public HTTPS endpoint. There is no pull
  equivalent, so a polling tool on a private box cannot see it, and no
  amount of configuration here will change that. The README says so
  plainly rather than letting it look like a gap in this code.
  """

  @all [:tags, :comments, :hashtag]

  # Cheap, and both need only the account's own token and permissions.
  # Hashtag search is opt-in: it spends from a budget of 30 unique
  # hashtags per rolling 7 days, which is easy to exhaust by accident.
  @default [:tags, :comments]

  @type source :: :tags | :comments | :hashtag

  @doc "Every source this fetcher knows how to read."
  @spec all() :: [source()]
  def all, do: @all

  @doc "The sources enabled unless configured otherwise."
  @spec default() :: [source()]
  def default, do: @default

  @doc """
  Normalises a configured source list, dropping anything unrecognised.

      iex> alias SmmMonitor.Fetchers.Instagram.Sources
      iex> Sources.normalize([:tags, :nonsense, "comments"])
      [:tags, :comments]
      iex> Sources.normalize(nil)
      [:tags, :comments]
  """
  @spec normalize(term()) :: [source()]
  def normalize(nil), do: @default

  def normalize(sources) do
    sources
    |> List.wrap()
    |> Enum.map(&to_source/1)
    |> Enum.filter(&(&1 in @all))
    |> Enum.uniq()
    |> case do
      [] -> []
      list -> list
    end
  end

  @doc """
  A one-line description of what a source can see, for logs and the
  README's table.
  """
  @spec describe(source()) :: String.t()
  def describe(:tags), do: "posts by others that @-tag the account"
  def describe(:comments), do: "comments on the account's own posts"
  def describe(:hashtag), do: "public posts carrying a tracked hashtag (no author)"

  defp to_source(source) when is_atom(source), do: source

  defp to_source(source) when is_binary(source) do
    case String.trim(source) do
      "tags" -> :tags
      "comments" -> :comments
      "hashtag" -> :hashtag
      _other -> :unknown
    end
  end

  defp to_source(_source), do: :unknown
end
