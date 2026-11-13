defmodule SmmMonitor.Fetchers.News do
  @moduledoc """
  News fetcher: RSS and Atom feeds, and optionally Google News search.

  Polled, like Reddit. Two sources, both optional:

    * **Your feeds** (`SMM_NEWS_FEEDS`, `SMM_NEWS_FEEDS_FILE`): any RSS
      2.0, RSS 1.0 or Atom feed. Every item is matched against each
      client's brand terms here, with `SmmMonitor.Matching`, the same
      whole-word matching the streams use.
    * **Google News search** (`SMM_NEWS_SEARCH=google`): one search per
      brand term per client per poll, at most `:max_terms` (5) terms a
      client. Off by default; Google's terms allow personal,
      non-commercial use of its feeds. See docs/platforms.md#news.

  ## Polite to the publishers

  A feed is shared by every client, so it is fetched once per poll, not
  once per client: the first client polled refreshes it and the rest
  match against what came back. Requests are conditional (`ETag`,
  `Last-Modified`), so an unchanged feed costs a `304`. A feed that fails
  is retried after 1, 2, 4 … up to 16 polls, and a `429` or `503` is
  honoured for as long as it asks. At most `:concurrency` (4) feeds are
  fetched at once.

  ## What counts as new

  Items published in the last `:lookback_ms` (24 hours) are considered.
  An item with no date is taken as old on the first read of a feed (it
  could be from any year) and as new when it first appears after that.
  A client is sent each item once; repeats are dropped again by the
  store in any case.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.News,
        feeds: ["https://example.com/feed.xml"],
        search: :off,            # or :google
        edition: "en-US",        # Google News language and country
        max_terms: 5,
        max_feeds: 100,
        max_items: 100,          # read from each feed
        lookback_ms: :timer.hours(24),
        concurrency: 4,
        max_body_bytes: 5 * 1024 * 1024
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :news, display_name: "News"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.News.{Feed, HTTP}
  alias SmmMonitor.Matching

  @google_url "https://news.google.com/rss/search"
  @default_edition "en-US"

  @default_max_terms 5
  @default_max_feeds 100
  @default_max_items 100
  @default_lookback_ms :timer.hours(24)
  @default_concurrency 4

  @max_backoff_polls 16
  # A feed fetch and parse that takes longer than this has hung.
  @task_timeout_ms 45_000
  @max_text 1_000

  defmodule State do
    @moduledoc false

    # feeds:   feed URL => cache entry (see `News.new_entry/0`)
    # polled:  the poll whose refresh is in `feeds`
    # sent:    client id => ids of items already handed to that client
    # search_until_ms / search_failing?: Google News back-off and logging
    defstruct feeds: %{},
              polled: nil,
              sent: %{},
              search_until_ms: nil,
              search_failing?: false

    @type t :: %__MODULE__{}
  end

  @impl true
  def init_state(_context), do: %State{}

  @impl true
  def ready?(context) do
    settings = settings(context)
    feed_urls(settings) != [] or search?(settings)
  end

  @impl true
  def fetch(context, state) do
    settings = settings(context)
    state = state || %State{}
    now_ms = now_ms(settings)

    state = refresh(state, context, settings, now_ms)
    from_feeds = from_feeds(context, state, settings, now_ms)
    {from_search, state} = from_search(context, state, settings, now_ms)
    {mentions, state} = only_new(context, from_feeds ++ from_search, state)

    case {mentions, failing_feeds(state, settings)} do
      {[], {failing, total}} when failing > 0 and failing == total and from_search == [] ->
        {:error, {:feeds_unreachable, failing}, state}

      _fine ->
        {:ok, mentions, state}
    end
  end

  @doc """
  Effective settings: module config, overridden by the platform's `:opts`.
  """
  @spec settings(Fetcher.context()) :: keyword()
  def settings(context) do
    :smm_monitor
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(Map.get(context, :opts) || [])
  end

  @doc """
  The feeds to read: the configured ones that may be fetched
  (`HTTP.fetchable?/1`), without repeats, at most `:max_feeds`.

      iex> SmmMonitor.Fetchers.News.feed_urls(
      ...>   feeds: ["https://a.example/rss", "http://b.example/rss", "https://a.example/rss"]
      ...> )
      ["https://a.example/rss"]
  """
  @spec feed_urls(keyword()) :: [String.t()]
  def feed_urls(settings) do
    settings
    |> Keyword.get(:feeds, [])
    |> List.wrap()
    |> Enum.filter(&HTTP.fetchable?/1)
    |> Enum.uniq()
    |> Enum.take(Keyword.get(settings, :max_feeds, @default_max_feeds))
  end

  @doc "Whether Google News search is switched on."
  @spec search?(keyword()) :: boolean()
  def search?(settings), do: Keyword.get(settings, :search) == :google

  @doc """
  The brand terms to search Google News for: trimmed, de-duplicated, at
  most `:max_terms`.

      iex> SmmMonitor.Fetchers.News.search_terms([" Acme ", "acme", "", "Acme Corp"], [])
      ["Acme", "Acme Corp"]
  """
  @spec search_terms([String.t()], keyword()) :: [String.t()]
  def search_terms(keywords, settings) do
    keywords
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(Keyword.get(settings, :max_terms, @default_max_terms))
  end

  @doc """
  Google News's language and country parameters for an edition such as
  `en-US` or `fr-CA`, or `:error`.

      iex> SmmMonitor.Fetchers.News.edition("en-GB")
      {:ok, [hl: "en-GB", gl: "GB", ceid: "GB:en"]}
      iex> SmmMonitor.Fetchers.News.edition("pt_br")
      {:ok, [hl: "pt-BR", gl: "BR", ceid: "BR:pt"]}
      iex> SmmMonitor.Fetchers.News.edition("English")
      :error
  """
  @spec edition(term()) :: {:ok, keyword()} | :error
  def edition(text) when is_binary(text) do
    case Regex.run(~r/\A([A-Za-z]{2,3})[-_]([A-Za-z]{2})\z/, String.trim(text)) do
      [_all, language, country] ->
        {language, country} = {String.downcase(language), String.upcase(country)}
        {:ok, [hl: "#{language}-#{country}", gl: country, ceid: "#{country}:#{language}"]}

      nil ->
        :error
    end
  end

  def edition(_other), do: :error

  @doc """
  The Google News search address for one brand term: the exact phrase,
  from the last day.
  """
  @spec google_url(String.t(), keyword()) :: String.t()
  def google_url(term, settings) do
    {:ok, edition} =
      with :error <- edition(Keyword.get(settings, :edition, @default_edition)),
           do: edition(@default_edition)

    phrase = term |> String.replace("\"", "") |> String.trim()
    query = URI.encode_query([q: ~s("#{phrase}" when:1d)] ++ edition)

    Keyword.get(settings, :google_url, @google_url) <> "?" <> query
  end

  # --- refreshing the feeds --------------------------------------------------

  # Once per poll: the first client polled refreshes, the rest reuse it.
  defp refresh(%State{polled: poll} = state, %{poll_count: poll}, _settings, _now_ms), do: state

  defp refresh(state, context, settings, now_ms) do
    urls = feed_urls(settings)
    feeds = Map.new(urls, &{&1, Map.get(state.feeds, &1, new_entry())})
    due = Enum.filter(urls, &(feeds[&1].retry_poll <= context.poll_count))

    feeds =
      due
      |> fetch_all(feeds, settings)
      |> Enum.reduce(feeds, fn {url, result}, feeds ->
        Map.update!(feeds, url, &update_entry(&1, url, result, context, settings, now_ms))
      end)

    %{state | feeds: feeds, polled: context.poll_count}
  end

  @doc false
  def new_entry do
    %{
      fetched?: false,
      etag: nil,
      last_modified: nil,
      title: nil,
      link: nil,
      items: [],
      failures: 0,
      retry_poll: 0,
      moved_logged?: false
    }
  end

  defp fetch_all([], _feeds, _settings), do: []

  defp fetch_all(urls, feeds, settings) do
    max_items = Keyword.get(settings, :max_items, @default_max_items)

    urls
    |> Task.async_stream(
      fn url -> fetch_feed(url, feeds[url], max_items, settings) end,
      max_concurrency: Keyword.get(settings, :concurrency, @default_concurrency),
      timeout: @task_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(urls)
    |> Enum.map(fn
      {{:ok, result}, url} -> {url, result}
      {{:exit, _reason}, url} -> {url, {:error, :timeout}}
    end)
  end

  defp fetch_feed(url, entry, max_items, settings) do
    validators = %{etag: entry.etag, last_modified: entry.last_modified}

    case HTTP.get(url, validators, settings) do
      {:ok, body, meta} ->
        case Feed.parse(body, url, max_items: max_items) do
          {:ok, feed} -> {:ok, feed, meta}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  rescue
    # The task is linked to the worker: one strange feed must not take
    # every other platform's poll down with it. Only the type is kept.
    exception -> {:error, {:crashed, exception.__struct__}}
  end

  defp update_entry(entry, url, {:ok, feed, meta}, _context, settings, now_ms) do
    if entry.failures > 0, do: Logger.info("news: #{label(url)} is reachable again")

    entry = note_moved(entry, url, meta)

    %{
      entry
      | fetched?: true,
        etag: meta.etag,
        last_modified: meta.last_modified,
        title: feed.title,
        link: feed.link,
        items: merge_items(entry, url, feed.items, settings, now_ms),
        failures: 0,
        retry_poll: 0
    }
  end

  defp update_entry(entry, url, {:not_modified, meta}, _context, settings, now_ms) do
    if entry.failures > 0, do: Logger.info("news: #{label(url)} is reachable again")

    entry = note_moved(entry, url, meta)
    cutoff = now_ms - lookback_ms(settings)

    %{entry | items: Enum.reject(entry.items, &expired?(&1, cutoff)), failures: 0, retry_poll: 0}
  end

  defp update_entry(entry, url, {:error, reason}, context, _settings, _now_ms) do
    failures = entry.failures + 1

    wait_polls =
      case reason do
        {:rate_limited, ms} -> max(1, ceil(ms / max(context.interval_ms, 1)))
        _other -> min(Integer.pow(2, failures - 1), @max_backoff_polls)
      end

    message = "news: #{label(url)} failed (#{describe(reason)}); next try in #{wait_polls} poll(s)"
    if failures == 1, do: Logger.warning(message), else: Logger.debug(message)

    %{entry | failures: failures, retry_poll: context.poll_count + wait_polls}
  end

  # Said once: the operator should update the address, but nothing breaks.
  defp note_moved(%{moved_logged?: false} = entry, url, %{moved_to: moved_to})
       when is_binary(moved_to) and moved_to != url do
    Logger.info(
      "news: #{label(url)} has moved permanently to #{label(moved_to)}; " <>
        "update SMM_NEWS_FEEDS to the new address"
    )

    %{entry | moved_logged?: true}
  end

  defp note_moved(entry, _url, _meta), do: entry

  # Each item gets a stable key and a publication time. Undated items keep
  # the time they were first seen at, so they are not new on every poll.
  defp merge_items(entry, url, items, settings, now_ms) do
    seen = Map.new(entry.items, &{&1.key, &1.published})
    now = DateTime.from_unix!(now_ms, :millisecond) |> DateTime.truncate(:second)
    cutoff = now_ms - lookback_ms(settings)

    items
    |> Enum.map(fn item ->
      key = key(url, item.guid || item.link || item.title)

      published =
        cond do
          item.published -> if DateTime.after?(item.published, now), do: now, else: item.published
          Map.has_key?(seen, key) -> seen[key]
          entry.fetched? -> now
          # The first read of a feed: an undated item could be from any year.
          true -> :undated
        end

      Map.merge(item, %{key: key, published: published})
    end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.reject(&expired?(&1, cutoff))
  end

  # Old dated items can never be shown, so they are not kept. Undated
  # ones are, or they would come back as new on the next read.
  defp expired?(%{published: :undated}, _cutoff), do: false

  defp expired?(%{published: published}, cutoff),
    do: DateTime.to_unix(published, :millisecond) < cutoff

  defp failing_feeds(state, settings) do
    if search?(settings) do
      {0, 0}
    else
      entries = Map.values(state.feeds)
      {Enum.count(entries, &(&1.failures > 0)), length(entries)}
    end
  end

  # --- matching the feeds ----------------------------------------------------

  defp from_feeds(context, state, settings, now_ms) do
    matcher = matcher(context.keywords)
    cutoff = now_ms - lookback_ms(settings)

    if Matching.empty?(matcher) do
      []
    else
      for {url, entry} <- state.feeds,
          item <- entry.items,
          not expired?(item, cutoff),
          item.published != :undated,
          Matching.clients_for(matcher, item.title <> " " <> item.summary) != [] do
        %{
          id: "news-" <> item.key,
          platform: :news,
          author: feed_author(item, entry, url),
          text: text(item.title, item.summary),
          url: item.link || entry.link,
          timestamp: item.published
        }
      end
    end
  end

  # The feed's own matching has nothing to do with the client struct: one
  # throwaway client with this client's terms.
  defp matcher(keywords) do
    Matching.build([%SmmMonitor.Client{id: "client", name: "client", keywords: keywords || []}])
  end

  defp feed_author(item, entry, url) do
    publisher = entry.title || URI.parse(url).host

    case item.author do
      nil -> publisher
      author when author == publisher -> author
      author -> "#{author} (#{publisher})"
    end
  end

  defp text(title, ""), do: title

  defp text(title, summary) do
    text = title <> " — " <> summary
    if String.length(text) > @max_text, do: String.slice(text, 0, @max_text - 1) <> "…", else: text
  end

  # --- Google News -----------------------------------------------------------

  defp from_search(context, state, settings, now_ms) do
    cond do
      not search?(settings) ->
        {[], state}

      state.search_until_ms != nil and now_ms < state.search_until_ms ->
        {[], state}

      true ->
        context.keywords
        |> search_terms(settings)
        |> Enum.reduce_while({[], state}, fn term, {found, state} ->
          case search(term, settings, now_ms) do
            {:ok, mentions} ->
              if state.search_failing?, do: Logger.info("news: Google News search works again")
              {:cont, {found ++ mentions, %{state | search_failing?: false, search_until_ms: nil}}}

            {:error, {:rate_limited, ms}} ->
              Logger.warning(
                "news: Google News is limiting requests; search pauses for " <>
                  "#{max(div(ms, 60_000), 1)} min. Feeds carry on."
              )

              {:halt, {found, %{state | search_until_ms: now_ms + ms, search_failing?: true}}}

            {:error, reason} ->
              unless state.search_failing? do
                Logger.warning("news: Google News search failed (#{describe(reason)})")
              end

              {:cont, {found, %{state | search_failing?: true}}}
          end
        end)
    end
  end

  defp search(term, settings, now_ms) do
    url = google_url(term, settings)
    cutoff = now_ms - lookback_ms(settings)
    now = DateTime.from_unix!(now_ms, :millisecond) |> DateTime.truncate(:second)

    with {:ok, body, _meta} <- HTTP.get(url, %{}, settings),
         {:ok, feed} <-
           Feed.parse(body, url, max_items: Keyword.get(settings, :max_items, @default_max_items)) do
      mentions =
        for %{published: %DateTime{} = published} = item <- feed.items,
            DateTime.to_unix(published, :millisecond) >= cutoff do
          publisher = item.source

          %{
            # Keyed on the article, not the search: two terms that find
            # the same story find one mention.
            id: "news-" <> key("google", item.guid || item.link || item.title),
            platform: :news,
            author: publisher || "Google News",
            text: google_title(item.title, publisher),
            url: item.link,
            timestamp: if(DateTime.after?(published, now), do: now, else: published)
          }
        end

      {:ok, mentions}
    else
      {:not_modified, _meta} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # Google appends " - Publisher" to every headline; the author column
  # already says who.
  defp google_title(title, nil), do: title

  defp google_title(title, publisher) do
    case String.trim_trailing(title, " - " <> publisher) do
      "" -> title
      trimmed -> trimmed
    end
  end

  # --- once per client --------------------------------------------------------

  # Each client is handed an item once. What it was sent is replaced by
  # what it would be sent now, so the set never outgrows the feeds.
  defp only_new(context, mentions, state) do
    client = if context.client, do: context.client.id, else: :none
    sent = Map.get(state.sent, client, MapSet.new())
    mentions = Enum.uniq_by(mentions, & &1.id)

    fresh = Enum.reject(mentions, &MapSet.member?(sent, &1.id))

    # Clients come and go; a map of thousands means most are gone.
    all_sent = if map_size(state.sent) > 1_000, do: %{}, else: state.sent
    current = MapSet.new(mentions, & &1.id)

    {fresh, %{state | sent: Map.put(all_sent, client, current)}}
  end

  # --- helpers -----------------------------------------------------------------

  defp key(scope, identity) do
    :sha256
    |> :crypto.hash([scope, "\n", identity || ""])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp lookback_ms(settings), do: Keyword.get(settings, :lookback_ms, @default_lookback_ms)

  # The host and path, never the query: a private feed's key lives there.
  defp label(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) -> host <> (path || "")
      _other -> "a feed"
    end
  end

  defp describe({:http_error, status}), do: "HTTP #{status}"
  defp describe({:rate_limited, ms}), do: "rate limited for #{div(ms, 1_000)} s"
  defp describe({:transport, reason}), do: "network: #{inspect(reason)}"
  defp describe({:bad_xml, reason}), do: "not valid XML: #{inspect(reason)}"
  defp describe({:bad_redirect, status}), do: "unsafe redirect (#{status})"
  defp describe({:unsupported_encoding, encoding}), do: "unsupported encoding #{encoding}"
  defp describe(:not_a_feed), do: "not an RSS or Atom feed"
  defp describe(:too_large), do: "larger than the size limit"
  defp describe(:too_many_redirects), do: "too many redirects"
  defp describe(:timeout), do: "timed out"
  defp describe(other), do: inspect(other)

  defp now_ms(settings) do
    case Keyword.get(settings, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _none -> System.system_time(:millisecond)
    end
  end
end
