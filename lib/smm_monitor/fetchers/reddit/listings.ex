defmodule SmmMonitor.Fetchers.Reddit.Listings do
  @moduledoc """
  What the Reddit fetcher remembers about the subreddits it reads.

  For a client with subreddits, Reddit is not searched: the newest posts
  (`/r/a+b/new`) and comments (`/r/a+b/comments`) are read and matched
  here, against the client's brand terms. That sees a post seconds after
  it is written, where Reddit's search index can take minutes, and it
  sees comments, which search never returns.

  The listings are shared. Every client's subreddits go into one
  multireddit read once per poll, however many clients there are, and
  each client is then matched against the items from its own
  subreddits only. So the struct holds:

    * `seen`: every item already read (fullname to `created_utc`), so a
      listing read every few seconds yields only what is new;
    * `buffer`: recent new items, newest first, each with a sequence
      number, kept for an hour or 2,000 items;
    * `cursors`: per client, the sequence number it has been given up
      to. A client is handed the buffered items past its cursor, so one
      that missed a poll (the cycle stopped at a rate limit) catches up
      on the next, and a new client starts with what is buffered;
    * `subs`: per client, its subreddits and the poll it was last seen
      in, so the first client of a poll can read everyone's subreddits
      at once.

  Pure functions over a struct, like `Reddit.RateLimit`: it lives in the
  worker's state.
  """

  alias SmmMonitor.Matching

  # A subreddit name as Reddit allows it. Anything else is dropped before
  # it can go into a request path.
  @subreddit ~r/\A[A-Za-z0-9][A-Za-z0-9_]{1,20}\z/

  @buffer_ms :timer.hours(1)
  @buffer_max 2_000
  @seen_max 20_000
  # A client not polled for this many polls no longer shapes the read.
  @forget_after_polls 20
  @max_text 500
  @max_body 1_000

  defstruct seen: %{},
            buffer: [],
            seq: 0,
            cursors: %{},
            subs: %{},
            poll: nil,
            fetched: MapSet.new(),
            failed: %{},
            primed: MapSet.new()

  @type item :: %{
          name: String.t(),
          kind: :post | :comment,
          id: String.t(),
          subreddit: String.t(),
          author: String.t(),
          title: String.t(),
          body: String.t(),
          permalink: String.t() | nil,
          created: integer(),
          seq: non_neg_integer(),
          added_ms: integer()
        }

  @type t :: %__MODULE__{}

  @doc "An empty memory."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The subreddit names that may go into a request, lower-cased, without
  `r/`, repeats or anything Reddit would not accept as a name.

      iex> SmmMonitor.Fetchers.Reddit.Listings.clean(["r/Marketing", "marketing", "../api", " SaaS "])
      ["marketing", "saas"]
  """
  @spec clean([term()] | term()) :: [String.t()]
  def clean(subreddits) do
    subreddits
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.trim_leading("r/")))
    |> Enum.filter(&Regex.match?(@subreddit, &1))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc "Whether `name` is a subreddit name Reddit would accept."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@subreddit, name)
  def valid?(_name), do: false

  @doc """
  Starts a new poll if `poll` is not the current one: forgets what was
  fetched last poll, drops old items and clients long gone.
  """
  @spec begin_poll(t(), integer(), integer(), integer()) :: t()
  def begin_poll(%__MODULE__{poll: poll} = listings, poll, _now_ms, _lookback_ms), do: listings

  def begin_poll(listings, poll, now_ms, lookback_ms) do
    seen_cutoff = div(now_ms - lookback_ms, 1_000)

    seen =
      listings.seen
      |> Map.reject(fn {_name, created} -> created < seen_cutoff end)
      |> cap_seen()

    buffer =
      listings.buffer
      |> Enum.filter(&(now_ms - &1.added_ms < @buffer_ms))
      |> Enum.take(@buffer_max)

    subs =
      Map.reject(listings.subs, fn {_client, {_subs, last}} -> poll - last > @forget_after_polls end)

    %{
      listings
      | poll: poll,
        seen: seen,
        buffer: buffer,
        subs: subs,
        cursors: Map.take(listings.cursors, Map.keys(subs)),
        fetched: MapSet.new(),
        failed: %{}
    }
  end

  @doc """
  Records the client's subreddits and returns what to read for it this
  poll: nothing if its subreddits were all read already, otherwise every
  known client's subreddits not yet read this poll.
  """
  @spec to_fetch(t(), term(), [String.t()]) :: {[String.t()], t()}
  def to_fetch(listings, client, subs) do
    listings = %{listings | subs: Map.put(listings.subs, client, {subs, listings.poll})}

    if Enum.all?(subs, &MapSet.member?(listings.fetched, &1)) do
      {[], listings}
    else
      all =
        listings.subs
        |> Map.values()
        |> Enum.flat_map(fn {subs, _poll} -> subs end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reject(&MapSet.member?(listings.fetched, &1))

      {all, listings}
    end
  end

  @doc "Marks subreddits as read this poll, or as failed with `reason`."
  @spec mark(t(), [String.t()], :ok | {:error, term()}) :: t()
  def mark(listings, subs, :ok),
    do: %{listings | fetched: MapSet.union(listings.fetched, MapSet.new(subs))}

  def mark(listings, subs, {:error, reason}) do
    %{
      listings
      | fetched: MapSet.union(listings.fetched, MapSet.new(subs)),
        failed: Enum.reduce(subs, listings.failed, &Map.put(&2, &1, reason))
    }
  end

  @doc "The failure, if any, that this poll's read of `subs` ran into."
  @spec failure(t(), [String.t()]) :: term() | nil
  def failure(listings, subs), do: Enum.find_value(subs, &Map.get(listings.failed, &1))

  @doc """
  Whether a listing of these subreddits has been read before. Only then
  does a page of nothing but new items mean a gap worth paging into; on
  the first read it just means everything is new.
  """
  @spec primed?(t(), atom(), [String.t()]) :: boolean()
  def primed?(listings, kind, subs),
    do: Enum.all?(subs, &MapSet.member?(listings.primed, {kind, &1}))

  @doc "Records that a listing of these subreddits has been read."
  @spec prime(t(), atom(), [String.t()]) :: t()
  def prime(listings, kind, subs),
    do: %{listings | primed: Enum.reduce(subs, listings.primed, &MapSet.put(&2, {kind, &1}))}

  @doc """
  Adds the items from a listing page. Every new one is remembered as
  seen; those from the lookback window also go into the buffer. Returns
  the listings and how many items were new.
  """
  @spec add(t(), [item()], integer(), integer()) :: {t(), non_neg_integer()}
  def add(listings, items, now_ms, lookback_ms) do
    cutoff = div(now_ms - lookback_ms, 1_000)

    new =
      items
      |> Enum.reject(&Map.has_key?(listings.seen, &1.name))
      |> Enum.uniq_by(& &1.name)

    seen = Enum.reduce(new, listings.seen, &Map.put(&2, &1.name, &1.created))

    {buffer_items, seq} =
      new
      |> Enum.filter(&(&1.created >= cutoff))
      |> Enum.sort_by(& &1.created)
      |> Enum.map_reduce(listings.seq, fn item, seq ->
        {Map.merge(item, %{seq: seq + 1, added_ms: now_ms}), seq + 1}
      end)

    buffer = Enum.take(Enum.reverse(buffer_items) ++ listings.buffer, @buffer_max)

    {%{listings | seen: seen, buffer: buffer, seq: seq}, length(new)}
  end

  @doc """
  The mention attrs for `client`: buffered items past its cursor, from
  its subreddits, that name one of its brand terms. The cursor moves on
  to the newest item.
  """
  @spec deliver(t(), term(), [String.t()], [String.t()]) :: {[map()], t()}
  def deliver(listings, client, subs, keywords) do
    cursor = Map.get(listings.cursors, client, 0)
    subs = MapSet.new(subs)
    matcher = matcher(keywords)

    mentions =
      if Matching.empty?(matcher) do
        []
      else
        listings.buffer
        |> Enum.take_while(&(&1.seq > cursor))
        |> Enum.filter(&MapSet.member?(subs, &1.subreddit))
        |> Enum.filter(&(Matching.clients_for(matcher, match_text(&1)) != []))
        |> Enum.reverse()
        |> Enum.map(&to_mention/1)
      end

    {mentions, %{listings | cursors: Map.put(listings.cursors, client, listings.seq)}}
  end

  @doc """
  Reads the items out of a `/new` or `/comments` listing. Deleted and
  removed items, and anything missing an id, author or subreddit, are
  dropped.
  """
  @spec parse(term()) :: [map()]
  def parse(%{"data" => %{"children" => children}}) when is_list(children) do
    Enum.flat_map(children, &item/1)
  end

  def parse(_body), do: []

  @doc "The `after` cursor of a page, which reads the page after it."
  @spec last_name(term()) :: String.t() | nil
  def last_name(%{"data" => %{"after" => after_name}}) when is_binary(after_name), do: after_name
  def last_name(_body), do: nil

  @doc "How many items a page held before any were dropped."
  @spec page_size(term()) :: non_neg_integer()
  def page_size(%{"data" => %{"children" => children}}) when is_list(children), do: length(children)
  def page_size(_body), do: 0

  @doc """
  The names in `subreddits` that `clean/1` drops as not subreddit names.
  Blank entries are not reported.

      iex> SmmMonitor.Fetchers.Reddit.Listings.invalid(["marketing", "../api", "", "a b"])
      ["../api", "a b"]
  """
  @spec invalid([term()] | term()) :: [String.t()]
  def invalid(subreddits) do
    subreddits
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.trim_leading("r/")))
    |> Enum.reject(&(&1 == "" or Regex.match?(@subreddit, &1)))
  end

  # --- internals ------------------------------------------------------------

  defp item(%{"kind" => "t3", "data" => %{"id" => id} = data}) when is_binary(id) do
    build(data, :post, "t3_" <> id, data["title"], data["selftext"])
  end

  defp item(%{"kind" => "t1", "data" => %{"id" => id} = data}) when is_binary(id) do
    build(data, :comment, "t1_" <> id, "", data["body"])
  end

  defp item(_child), do: []

  defp build(data, kind, name, title, body) do
    with author when is_binary(author) and author != "[deleted]" <- data["author"],
         sub when is_binary(sub) <- data["subreddit"],
         created when is_number(created) <- data["created_utc"],
         title = string(title),
         body = string(body),
         false <- body in ["[removed]", "[deleted]"] and title == "",
         false <- title == "" and body == "" do
      [
        %{
          name: name,
          kind: kind,
          id: data["id"],
          subreddit: String.downcase(sub),
          author: author,
          title: String.slice(title, 0, @max_text),
          body: String.slice(body, 0, @max_body),
          permalink: permalink(data["permalink"]),
          created: trunc(created)
        }
      ]
    else
      _dropped -> []
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp permalink("/" <> _rest = path), do: path
  defp permalink(_other), do: nil

  defp match_text(%{title: title, body: body}), do: title <> "\n" <> body

  # The same id as a search result, so a post found both ways is stored
  # once. Comments are prefixed, since their ids are a separate series.
  defp to_mention(%{kind: :post} = item) do
    %{
      id: "reddit-" <> item.id,
      platform: :reddit,
      author: "u/" <> item.author,
      text: [item.title, item.body] |> Enum.reject(&(&1 == "")) |> Enum.join(" — ") |> cut(),
      url: link(item.permalink),
      timestamp: item.created
    }
  end

  defp to_mention(%{kind: :comment} = item) do
    %{
      id: "reddit-" <> item.name,
      platform: :reddit,
      author: "u/" <> item.author,
      text: cut(item.body),
      url: link(item.permalink),
      timestamp: item.created
    }
  end

  defp cut(text), do: String.slice(text, 0, @max_text)

  # Always reddit.com plus the permalink, as for search results.
  defp link(nil), do: nil
  defp link(path), do: "https://reddit.com" <> path

  defp matcher(keywords) do
    Matching.build([%SmmMonitor.Client{id: "client", name: "client", keywords: keywords || []}])
  end

  defp cap_seen(seen) when map_size(seen) <= @seen_max, do: seen

  defp cap_seen(seen) do
    seen
    |> Enum.sort_by(fn {_name, created} -> created end, :desc)
    |> Enum.take(@seen_max)
    |> Map.new()
  end
end
