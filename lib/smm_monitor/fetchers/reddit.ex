defmodule SmmMonitor.Fetchers.Reddit do
  @moduledoc """
  Reddit fetcher — the one platform pulling **live** data.

  Uses the free "script" app type and its `client_credentials` grant: no
  user, no redirect, no approval wait. See the README for how to create one
  at <https://www.reddit.com/prefs/apps>.

  Reddit is read two ways, depending on the client:

    * **A client with subreddits** has them read directly: the newest
      posts (`/r/a+b/new`) and comments (`/r/a+b/comments`), matched here
      against its brand terms. A post shows up one poll after it is
      written, 15 seconds by default, where search can take minutes to
      index it, and comments are seen, which search never returns. Every
      client's subreddits are read together once per poll, 50 to a
      request, so adding clients does not add requests unless it adds
      subreddits. See `SmmMonitor.Fetchers.Reddit.Listings`.
    * **A client with no subreddits** has all of Reddit searched
      (`/search`), every 30 seconds whatever the poll interval, since
      there is no listing of everything to read instead. So does a
      `:query` setting, which is Reddit search syntax.

  Every request checks the quota Reddit last reported first
  (`Reddit.RateLimit`), and a refused or spent quota stops the poll.

  State carried between polls (`SmmMonitor.Fetchers.Reddit.State`) is the
  cached OAuth token, the rate-limit quota and the listings already read.
  It lives in the worker's GenServer state.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.Reddit,
        subreddits: ["smallbusiness", "marketing"],
        # Read comments in the subreddits as well as posts.
        comments: true,
        # Site-wide search, for clients with no subreddits.
        search_interval_ms: 30_000,
        limit: 50,
        sort: "new",
        time_filter: "day"

  Credentials come from the setup wizard or the environment via
  `config/runtime.exs`: `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` and
  optionally `REDDIT_USER_AGENT`. Without them the worker collects nothing
  and the dashboard shows Reddit as not connected.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :reddit, display_name: "Reddit"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.Reddit.{Auth, Listings, RateLimit, State}

  @api_host "https://oauth.reddit.com"
  @default_limit 50
  @default_sort "new"
  @default_time_filter "day"

  # Reddit caps a listing at 100 items per request.
  @max_limit 100
  @page_size 100
  # A gap is filled from at most this many pages of one listing.
  @max_pages 3
  # Subreddits per multireddit request, which keeps the URL short.
  @subs_per_request 50
  @default_search_interval_ms 30_000
  # Items older than this are never handed to a client.
  @lookback_ms :timer.hours(24)
  @bad_sub_ms :timer.hours(1)

  @impl true
  def init_state(_context), do: State.new()

  @impl true
  def ready?(%{credentials: credentials}) do
    present?(credentials[:client_id]) and present?(credentials[:client_secret])
  end

  @impl true
  def fetch(context, state) do
    state = state || State.new()
    settings = settings(context)
    now = now_ms(settings)
    client = client_id(context)
    state = warn_invalid(state, Keyword.get(settings, :subreddits, []))

    case listing_subs(settings) do
      [] -> search_if_due(context, state, settings, client, now)
      subs -> read_listings(context, state, settings, client, subs, now)
    end
  end

  @doc """
  Effective settings: module config, then the subreddit list of the client
  being polled for, then anything in the platform's `:opts`.

  Subreddits are per client, not global: one client's brand lives in
  r/marketing and another's in r/gamedev, and searching both lists for
  both clients would return noise for each.

  The `:opts` override is last so tests can inject a stub transport and a
  fixed subreddit list.
  """
  @spec settings(Fetcher.context()) :: keyword()
  def settings(context) do
    opts = Map.get(context, :opts) || []

    :smm_monitor
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(client_settings(context, opts))
    |> Keyword.merge(opts)
  end

  # Skipped when :opts already pins the subreddits.
  defp client_settings(context, opts) do
    if Keyword.has_key?(opts, :subreddits) do
      []
    else
      [subreddits: Map.get(context, :subreddits) || []]
    end
  end

  @doc """
  Builds the Reddit search query from the configured keywords.

  Multi-word terms are quoted so Reddit treats them as a phrase, and terms
  are OR-ed together. An explicit `:query` setting wins, for anyone who
  wants Reddit's own search syntax.

      iex> alias SmmMonitor.Fetchers.Reddit
      iex> Reddit.build_query(["realoffice"], [])
      "realoffice"
      iex> Reddit.build_query(["realoffice", "real office"], [])
      ~s(realoffice OR "real office")
      iex> Reddit.build_query(["ignored"], query: "flair:review")
      "flair:review"
  """
  @spec build_query([String.t()], keyword()) :: String.t()
  def build_query(keywords, settings \\ []) do
    case Keyword.get(settings, :query) do
      query when is_binary(query) and query != "" ->
        query

      _none ->
        keywords
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.map_join(" OR ", &quote_if_phrase/1)
    end
  end

  @doc """
  The search path for the configured subreddits.

  Several subreddits become one multireddit request; none means site-wide.

      iex> SmmMonitor.Fetchers.Reddit.search_path([])
      "/search"
      iex> SmmMonitor.Fetchers.Reddit.search_path(["marketing"])
      "/r/marketing/search"
      iex> SmmMonitor.Fetchers.Reddit.search_path(["marketing", "smallbusiness"])
      "/r/marketing+smallbusiness/search"
      iex> SmmMonitor.Fetchers.Reddit.search_path(["marketing", "../api/v1/me"])
      "/r/marketing/search"
  """
  @spec search_path([String.t()]) :: String.t()
  def search_path(subreddits) do
    case Listings.clean(subreddits) do
      [] -> "/search"
      subs -> "/r/#{Enum.join(subs, "+")}/search"
    end
  end

  @doc """
  Maps a Reddit listing payload onto mention attrs.

  Public and pure, so it can be exercised against a saved API response
  with no network access. Posts missing an id or author are dropped rather
  than stored as junk.
  """
  @spec parse(map() | term()) :: [map()]
  def parse(%{"data" => %{"children" => children}}) when is_list(children) do
    children
    |> Enum.map(&post_data/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_mention_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_body), do: []

  # --- internals ------------------------------------------------------------

  # --- site-wide search -------------------------------------------------------

  # Search runs on its own cadence, 30 seconds by default, however often
  # the worker polls: the listings below are what the short interval is
  # for. A second's slack keeps a 30-second search from slipping to 45
  # when the worker's timer fires a little early.
  defp search_if_due(context, state, settings, client, now) do
    interval = Keyword.get(settings, :search_interval_ms, @default_search_interval_ms)

    case Map.get(state.searched_at, client) do
      last when is_integer(last) and now - last < interval - 1_000 ->
        {:ok, [], state}

      _due ->
        case search(context, state, settings) do
          {:ok, body, state} ->
            {:ok, parse(body), %{state | searched_at: Map.put(state.searched_at, client, now)}}

          error ->
            error
        end
    end
  end

  defp search(context, state, settings) do
    subreddits = Listings.clean(Keyword.get(settings, :subreddits, []))

    get(context, state, settings, search_path(subreddits),
      q: build_query(context.keywords, settings),
      sort: Keyword.get(settings, :sort, @default_sort),
      t: Keyword.get(settings, :time_filter, @default_time_filter),
      limit: limit(settings),
      type: "link",
      # Without this, a subreddit-scoped search still returns site-wide hits.
      restrict_sr: subreddits != [],
      raw_json: 1
    )
  end

  # --- subreddit listings -----------------------------------------------------

  # The subreddits to read listings for. A `:query` setting is Reddit
  # search syntax, which a listing cannot apply, so it keeps search.
  defp listing_subs(settings) do
    case Keyword.get(settings, :query) do
      query when is_binary(query) and query != "" -> []
      _none -> Listings.clean(Keyword.get(settings, :subreddits, []))
    end
  end

  defp read_listings(context, state, settings, client, subs, now) do
    {state, live} = drop_bad(state, subs, now)

    listings =
      state.listings
      |> Listings.begin_poll(Map.get(context, :poll_count, 0), now, @lookback_ms)
      |> Listings.to_fetch(client, live)

    {wanted, listings} = listings
    wanted = Enum.reject(wanted, &Map.has_key?(state.bad_subs, &1))
    state = %{state | listings: listings}

    with {:ok, state} <-
           read_chunks(Enum.chunk_every(wanted, @subs_per_request), context, state, settings, now) do
      deliver(state, client, subs, context.keywords, now)
    end
  end

  defp deliver(state, client, subs, keywords, now) do
    {state, live} = drop_bad(state, subs, now)

    cond do
      live == [] ->
        {reason, _until} = Map.fetch!(state.bad_subs, hd(subs))
        {:error, reason, state}

      reason = Listings.failure(state.listings, live) ->
        {:error, reason, state}

      true ->
        {mentions, listings} = Listings.deliver(state.listings, client, live, keywords)
        {:ok, mentions, %{state | listings: listings}}
    end
  end

  # Subreddits Reddit refused within the hour are left out; the rest of
  # the client's list is still read.
  defp drop_bad(state, subs, now) do
    bad_subs = Map.reject(state.bad_subs, fn {_sub, {_reason, until}} -> until <= now end)
    {%{state | bad_subs: bad_subs}, Enum.reject(subs, &Map.has_key?(bad_subs, &1))}
  end

  defp read_chunks([], _context, state, _settings, _now), do: {:ok, state}

  defp read_chunks([subs | rest], context, state, settings, now) do
    case read_chunk(subs, context, state, settings, now) do
      {:ok, state} ->
        read_chunks(rest, context, state, settings, now)

      # Out of quota, a refused token or no network: the rest would fail
      # the same way, so every client this poll is told rather than each
      # trying again.
      {:error, reason, state} ->
        listings = Listings.mark(state.listings, Enum.concat([subs | rest]), {:error, reason})
        {:error, reason, %{state | listings: listings}}
    end
  end

  # One multireddit, read for posts and then comments. An error that is
  # about these subreddits (a 404 for a banned one, a 500) is recorded
  # against them and the poll goes on; anything else stops it.
  defp read_chunk(subs, context, state, settings, now) do
    kinds = if Keyword.get(settings, :comments, true), do: [:new, :comments], else: [:new]

    result =
      Enum.reduce_while(kinds, {:ok, state}, fn kind, {:ok, state} ->
        case read_pages(subs, kind, nil, 1, context, state, settings, now) do
          {:ok, state} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, state} ->
        {:ok, %{state | listings: Listings.mark(state.listings, subs, :ok)}}

      {:error, {:http_error, status}, state} when status in 300..399 or status in [403, 404] ->
        refused(subs, status, context, state, settings, now)

      {:error, {:http_error, _status} = reason, state} ->
        {:ok, %{state | listings: Listings.mark(state.listings, subs, {:error, reason})}}

      error ->
        error
    end
  end

  # Reddit answers a multireddit with one private, banned or misspelt
  # subreddit by refusing the lot, so the subreddits are tried one by one
  # to find which. Only the refused ones are then left out.
  defp refused([sub], status, _context, state, _settings, now) do
    Logger.warning(
      "reddit: r/#{sub} could not be read (HTTP #{status}). It may be private, banned or " <>
        "misspelt; it is skipped for an hour. Check the client's subreddits."
    )

    state = %{
      state
      | bad_subs: Map.put(state.bad_subs, sub, {{:http_error, status}, now + @bad_sub_ms}),
        listings: Listings.mark(state.listings, [sub], :ok)
    }

    {:ok, state}
  end

  defp refused(subs, _status, context, state, settings, now) do
    Enum.reduce_while(subs, {:ok, state}, fn sub, {:ok, state} ->
      case read_chunk([sub], context, state, settings, now) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  # A listing is read a page of 100 at a time, newest first. Once it has
  # been read before, a full page of nothing but new items means more
  # arrived since the last poll than a page holds (the cycle was paused,
  # or the subreddits are busy), so the next page is read too, up to
  # three. The first read takes one page: there is no gap to fill yet.
  defp read_pages(subs, kind, after_name, page, context, state, settings, now) do
    params = [limit: @page_size, raw_json: 1] ++ if(after_name, do: [after: after_name], else: [])
    primed? = Listings.primed?(state.listings, kind, subs)

    case get(context, state, settings, listing_path(subs, kind), params, redirect: false) do
      {:ok, body, state} ->
        items = Listings.parse(body)
        {listings, new} = Listings.add(state.listings, items, now, @lookback_ms)
        state = %{state | listings: listings}
        next = Listings.last_name(body)

        gap? =
          primed? and items != [] and new == length(items) and
            Listings.page_size(body) >= @page_size and is_binary(next) and page < @max_pages

        if gap? do
          read_pages(subs, kind, next, page + 1, context, state, settings, now)
        else
          {:ok, %{state | listings: Listings.prime(state.listings, kind, subs)}}
        end

      error ->
        error
    end
  end

  defp listing_path(subs, :new), do: "/r/#{Enum.join(subs, "+")}/new"
  defp listing_path(subs, :comments), do: "/r/#{Enum.join(subs, "+")}/comments"

  # --- requests ---------------------------------------------------------------

  # Every request goes through here: the quota is checked first, so a
  # request is never spent when Reddit has said there is none left.
  defp get(context, state, settings, path, params, extra \\ []) do
    req_options = Keyword.get(settings, :req_options, [])

    with :ok <- RateLimit.check(state.rate_limit),
         {:ok, token, auth} <- Auth.token(state.auth, context.credentials, req_options) do
      state = %{state | auth: auth, rate_limit: RateLimit.record_request(state.rate_limit)}

      [
        url: @api_host <> path,
        params: params,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"user-agent", Auth.user_agent(context.credentials)}
        ],
        receive_timeout: 10_000,
        # Retrying is the worker's job, not Req's. A blind retry of a 429
        # spends quota we've just been told we don't have, and blocks the
        # worker for seconds while it sleeps between attempts.
        retry: false
      ]
      |> Keyword.merge(extra)
      |> Kernel.++(req_options)
      |> Req.new()
      |> Req.request()
      |> handle_response(state)
    else
      {:backoff, wait_ms} ->
        # Tell the worker to postpone rather than burning the request now.
        Logger.info("reddit: near the rate limit, backing off for #{wait_ms}ms")
        {:error, {:rate_limited, wait_ms}, state}

      {:error, reason, %Auth{} = auth} ->
        {:error, reason, %{state | auth: auth}}
    end
  end

  defp handle_response({:ok, %{status: 200, body: body, headers: headers}}, state) do
    {:ok, body, %{state | rate_limit: RateLimit.observe(state.rate_limit, headers)}}
  end

  # The token was rejected despite looking fresh — drop it so the next poll
  # fetches a new one rather than failing the same way forever.
  defp handle_response({:ok, %{status: 401}}, state) do
    {:error, :unauthorized, %{state | auth: Auth.invalidate(state.auth)}}
  end

  defp handle_response({:ok, %{status: 429, headers: headers}}, state) do
    rate_limit = RateLimit.observe(state.rate_limit, headers)

    wait_ms =
      case RateLimit.check(rate_limit) do
        {:backoff, ms} -> ms
        :ok -> :timer.minutes(1)
      end

    {:error, {:rate_limited, wait_ms}, %{state | rate_limit: rate_limit}}
  end

  defp handle_response({:ok, %{status: status, headers: headers}}, state) do
    {:error, {:http_error, status},
     %{state | rate_limit: RateLimit.observe(state.rate_limit, headers)}}
  end

  defp handle_response({:error, reason}, state) do
    {:error, {:transport, reason}, state}
  end

  # --- helpers ----------------------------------------------------------------

  # A name that is not a subreddit never reaches a request path. Said once
  # per name, since the client record will keep offering it every poll.
  defp warn_invalid(state, subreddits) do
    subreddits
    |> Listings.invalid()
    |> Enum.reject(&MapSet.member?(state.warned, &1))
    |> Enum.reduce(state, fn name, state ->
      Logger.warning("reddit: ignoring #{inspect(name)}, which is not a subreddit name")
      %{state | warned: MapSet.put(state.warned, name)}
    end)
  end

  defp client_id(%{client: %{id: id}}), do: id
  defp client_id(_context), do: :none

  defp now_ms(settings) do
    case Keyword.get(settings, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _none -> System.system_time(:millisecond)
    end
  end

  defp post_data(%{"data" => %{} = post}), do: post
  defp post_data(_child), do: nil

  defp to_mention_attrs(%{"id" => id, "author" => author} = post)
       when is_binary(id) and is_binary(author) do
    %{
      id: "reddit-#{id}",
      platform: :reddit,
      author: "u/#{author}",
      text: text_of(post),
      url: permalink(post),
      timestamp: timestamp(post)
    }
  end

  defp to_mention_attrs(_post), do: nil

  # A Reddit post is a title plus optional selftext; the title is usually
  # the mention, so it leads, and the body is trimmed.
  defp text_of(post) do
    [post["title"], post["selftext"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" — ")
    |> String.slice(0, 500)
  end

  # Always a reddit.com link built from the permalink. A link post's own
  # "url" field points wherever its author chose, so it is never used: a
  # mention's link must go to the discussion, not to a stranger's site.
  defp permalink(%{"permalink" => "/" <> _ = permalink}) do
    "https://reddit.com" <> permalink
  end

  defp permalink(_post), do: nil

  # created_utc is unix seconds, and arrives as a float.
  defp timestamp(%{"created_utc" => created}) when is_number(created), do: trunc(created)
  defp timestamp(_post), do: nil

  defp limit(settings) do
    settings
    |> Keyword.get(:limit, @default_limit)
    |> min(@max_limit)
    |> max(1)
  end

  defp quote_if_phrase(keyword) do
    keyword = String.trim(keyword)
    if String.contains?(keyword, " "), do: ~s("#{keyword}"), else: keyword
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
