defmodule SmmMonitor.Fetchers.Reddit do
  @moduledoc """
  Reddit fetcher — the one platform pulling **live** data.

  Uses the free "script" app type and its `client_credentials` grant: no
  user, no redirect, no approval wait. See the README for how to create one
  at <https://www.reddit.com/prefs/apps>.

  Each poll is a single HTTP request. The configured subreddits are joined
  into one multireddit search (`/r/a+b+c/search`) rather than one request
  per subreddit, which keeps a poll to one request against the 60/minute
  budget no matter how many subreddits are being watched. With no
  subreddits configured it falls back to a site-wide `/search`.

  State carried between polls (`SmmMonitor.Fetchers.Reddit.State`) is the
  cached OAuth token and the rate-limit quota. Both live in the worker's
  GenServer state.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.Reddit,
        subreddits: ["smallbusiness", "marketing"],
        limit: 50,
        sort: "new",
        time_filter: "week"

  Credentials come from the environment via `config/runtime.exs`:
  `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` and optionally
  `REDDIT_USER_AGENT`. Without them the worker keeps this platform on mock
  data and logs why.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :reddit, display_name: "Reddit"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.Reddit.{Auth, RateLimit, State}

  @search_host "https://oauth.reddit.com"
  @default_limit 50
  @default_sort "new"
  @default_time_filter "week"

  # Reddit caps a listing at 100 items per request.
  @max_limit 100

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
    req_options = Keyword.get(settings, :req_options, [])

    case RateLimit.check(state.rate_limit) do
      {:backoff, wait_ms} ->
        # Tell the worker to postpone rather than burning the request now.
        Logger.info("reddit: near the rate limit, backing off for #{wait_ms}ms")
        {:error, {:rate_limited, wait_ms}, state}

      :ok ->
        do_fetch(context, state, settings, req_options)
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
  """
  @spec search_path([String.t()]) :: String.t()
  def search_path(subreddits) do
    case clean_subreddits(subreddits) do
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

  defp do_fetch(context, state, settings, req_options) do
    credentials = context.credentials

    with {:ok, token, auth} <- Auth.token(state.auth, credentials, req_options),
         state = %{state | auth: auth},
         {:ok, body, state} <- search(token, context, state, settings, req_options) do
      {:ok, parse(body), state}
    else
      {:error, reason, %State{} = state} -> {:error, reason, state}
      {:error, reason, %Auth{} = auth} -> {:error, reason, %{state | auth: auth}}
    end
  end

  defp search(token, context, state, settings, req_options) do
    subreddits = Keyword.get(settings, :subreddits, [])

    request =
      Req.new(
        [
          url: @search_host <> search_path(subreddits),
          params: search_params(context, settings, subreddits),
          headers: [
            {"authorization", "Bearer #{token}"},
            {"user-agent", Auth.user_agent(context.credentials)}
          ],
          receive_timeout: 10_000,
          # Retrying is the worker's job, not Req's. A blind retry of a 429
          # spends quota we've just been told we don't have, and blocks the
          # worker for seconds while it sleeps between attempts.
          retry: false
        ] ++ req_options
      )

    state = %{state | rate_limit: RateLimit.record_request(state.rate_limit)}

    request
    |> Req.request()
    |> handle_search_response(state)
  end

  defp search_params(context, settings, subreddits) do
    [
      q: build_query(context.keywords, settings),
      sort: Keyword.get(settings, :sort, @default_sort),
      t: Keyword.get(settings, :time_filter, @default_time_filter),
      limit: limit(settings),
      type: "link",
      # Without this, a subreddit-scoped search still returns site-wide hits.
      restrict_sr: clean_subreddits(subreddits) != [],
      raw_json: 1
    ]
  end

  defp handle_search_response({:ok, %{status: 200, body: body, headers: headers}}, state) do
    {:ok, body, %{state | rate_limit: RateLimit.observe(state.rate_limit, headers)}}
  end

  # The token was rejected despite looking fresh — drop it so the next poll
  # fetches a new one rather than failing the same way forever.
  defp handle_search_response({:ok, %{status: 401}}, state) do
    {:error, :unauthorized, %{state | auth: Auth.invalidate(state.auth)}}
  end

  defp handle_search_response({:ok, %{status: 429, headers: headers}}, state) do
    rate_limit = RateLimit.observe(state.rate_limit, headers)

    wait_ms =
      case RateLimit.check(rate_limit) do
        {:backoff, ms} -> ms
        :ok -> :timer.minutes(1)
      end

    {:error, {:rate_limited, wait_ms}, %{state | rate_limit: rate_limit}}
  end

  defp handle_search_response({:ok, %{status: status}}, state) do
    {:error, {:http_error, status}, state}
  end

  defp handle_search_response({:error, reason}, state) do
    {:error, {:transport, reason}, state}
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

  defp permalink(%{"permalink" => permalink}) when is_binary(permalink) do
    "https://reddit.com" <> permalink
  end

  defp permalink(%{"url" => url}) when is_binary(url), do: url
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

  defp clean_subreddits(subreddits) do
    subreddits
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.trim_leading("r/")))
    |> Enum.reject(&(&1 == ""))
  end

  defp quote_if_phrase(keyword) do
    keyword = String.trim(keyword)
    if String.contains?(keyword, " "), do: ~s("#{keyword}"), else: keyword
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
