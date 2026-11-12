defmodule SmmMonitor.Fetchers.Threads do
  @moduledoc """
  Threads fetcher, polling Meta's Threads API.

  Threads has no live stream to subscribe to, so this is a polled platform
  like Reddit and YouTube. Each poll, for each client, it reads the
  sources in `SmmMonitor.Fetchers.Threads.Sources`: keyword search for the
  client's brand terms and the connected account's mentions by default,
  plus replies to the account's own posts if asked.

  ## Read this before trusting the Threads tab

  **Until Meta approves the app in App Review, search only finds the
  connected account's own posts**, and mentions only come from the app's
  testers. The fetcher works the same either way; what changes is what
  Meta lets it see. docs/platforms.md walks through it.

  ## Limits

    * Keyword search: 2,200 queries per rolling 24 hours per Threads user,
      shared across apps. Counted in `Threads.QueryBudget` against a
      budget of 2,000 by default. One query per brand term per client per
      poll, at most `:max_terms` (10) terms per client.
    * Everything else: Meta's usual rate limiting. A throttling error
      (`4`, `17`, `32`, `613`) or a 429 stops the poll for every client
      until Meta's stated wait has passed.

  ## Tokens

  A long-lived token lasts 60 days; `Threads.Token` renews it in the
  background and keeps the renewed one in a private file. Meta takes the
  token as a query parameter, so request URLs are never logged.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.Threads,
        sources: [:search, :mentions],
        daily_query_budget: 2_000,
        search_limit: 50,
        max_terms: 10
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :threads, display_name: "Threads"

  require Logger

  alias SmmMonitor.Fetchers.{Fetcher, MetaGraph}
  alias SmmMonitor.Fetchers.Threads.{QueryBudget, Sources, State, Token}
  alias SmmMonitor.Matching

  @graph_host "https://graph.threads.net"
  @api_version "v1.0"

  @post_fields "id,text,media_type,permalink,timestamp,username"
  @own_post_fields "id,permalink,timestamp,has_replies"

  @default_search_limit 50
  @default_max_terms 10
  @own_posts_limit 10
  @replies_limit 25

  # The first poll looks back a day, like Reddit and YouTube.
  @first_lookback_s 24 * 3_600
  # Later polls re-read a little before the newest post seen, so a post
  # Meta indexes a few minutes late isn't skipped. Repeats are dropped by
  # id further down the line.
  @overlap_s 10 * 60
  # Meta rejects a `since` before Threads' launch.
  @earliest_since 1_688_540_400

  # Used when Meta throttles without saying for how long.
  @default_throttle_ms :timer.minutes(15)

  @id_pattern ~r/\A\d{1,25}\z/
  @username_pattern ~r/\A[A-Za-z0-9._]{1,30}\z/
  @permalink_hosts ~w(threads.com www.threads.com threads.net www.threads.net)

  @impl true
  def init_state(context) do
    State.new(Keyword.get(settings(context), :daily_query_budget))
  end

  @impl true
  def ready?(%{credentials: credentials}), do: present?(credentials[:access_token])

  @impl true
  def fetch(context, state) do
    settings = settings(context)
    state = state || State.new(Keyword.get(settings, :daily_query_budget))
    now_ms = now_ms(settings)

    state =
      state
      |> Token.current(context.credentials[:access_token], settings, now_ms)
      |> check_cadence(context, settings)

    collect(context, state, settings, now_ms)
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
  The terms to search for: trimmed, de-duplicated, at most `max_terms`.

      iex> alias SmmMonitor.Fetchers.Threads
      iex> Threads.search_terms([" Acme ", "acme", "", "acme corp"], [])
      ["Acme", "acme corp"]
      iex> Threads.search_terms(["a", "b", "c"], max_terms: 2)
      ["a", "b"]
  """
  @spec search_terms([String.t()], keyword()) :: [String.t()]
  def search_terms(keywords, settings) do
    keywords
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(max_terms(settings))
  end

  @doc """
  Maps a list of Threads posts (`{"data": [...]}`) onto mention attrs.

  Public and pure, so it runs against a saved response with no network.
  A post whose id isn't numeric is dropped; an unexpected username becomes
  `@unknown`; a permalink to anywhere but Threads becomes no link.
  """
  @spec parse_posts(map() | term()) :: [map()]
  def parse_posts(%{"data" => posts}) when is_list(posts) do
    posts
    |> Enum.map(&post_to_mention/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse_posts(_body), do: []

  @doc """
  The permalink, if it is an `https` link to Threads; otherwise nil.

      iex> alias SmmMonitor.Fetchers.Threads
      iex> Threads.permalink("https://www.threads.com/@acme/post/C1a2b3")
      "https://www.threads.com/@acme/post/C1a2b3"
      iex> Threads.permalink("https://threads.com.evil.example/@acme/post/1")
      nil
      iex> Threads.permalink("javascript:alert(1)")
      nil
  """
  @spec permalink(term()) :: String.t() | nil
  def permalink(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when host in @permalink_hosts ->
        url

      _other ->
        nil
    end
  end

  def permalink(_url), do: nil

  # --- sources --------------------------------------------------------------

  defp collect(context, state, settings, now_ms) do
    sources = Sources.normalize(Keyword.get(settings, :sources))

    {results, state} =
      Enum.reduce(sources, {[], state}, fn source, {results, state} ->
        case stop_reason(results) do
          # Throttled or a dead token: every other call would fail the
          # same way, so don't make them.
          {:error, reason} ->
            {[{:error, reason} | results], state}

          nil ->
            {result, state} = run_source(source, context, state, settings, now_ms)
            {[result | results], state}
        end
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _mentions}, &1))

    mentions =
      successes
      |> Enum.flat_map(fn {:ok, mentions} -> mentions end)
      |> Enum.uniq_by(& &1.id)

    cond do
      sources == [] -> {:error, :no_sources_enabled, state}
      successes == [] -> {:error, first_reason(Enum.reverse(failures)), state}
      true -> {:ok, mentions, state}
    end
  end

  defp stop_reason(results) do
    Enum.find(results, fn
      {:error, {:rate_limited, _ms}} -> true
      {:error, {:expired_access_token, _message}} -> true
      _other -> false
    end)
  end

  defp run_source(source, context, state, settings, now_ms) do
    case fetch_source(source, context, state, settings, now_ms) do
      {:ok, mentions, state} ->
        {{:ok, mentions}, state}

      # Logged once, by the search itself, rather than once per client.
      {:error, {:quota_exhausted, _ms} = reason, state} ->
        {{:error, reason}, state}

      {:error, reason, state} ->
        Logger.warning(
          "threads: #{source} (#{Sources.describe(source)}) failed: #{describe(reason)}"
        )

        {{:error, reason}, state}
    end
  end

  defp fetch_source(:search, context, state, settings, now_ms) do
    terms = search_terms(context.keywords, settings)

    {mentions, answered, errors, state} =
      Enum.reduce_while(terms, {[], 0, [], state}, fn term, {mentions, answered, errors, state} ->
        case search(term, context, state, settings, now_ms) do
          {:ok, found, state} ->
            {:cont, {found ++ mentions, answered + 1, errors, state}}

          # Shared limits: the remaining terms would fail the same way.
          {:error, reason, state}
          when elem(reason, 0) in [:quota_exhausted, :rate_limited, :expired_access_token] ->
            {:halt, {mentions, answered, [reason | errors], state}}

          {:error, reason, state} ->
            {:cont, {mentions, answered, [reason | errors], state}}
        end
      end)

    # Some terms answered: keep what they found. A term that failed is
    # tried again next poll.
    if terms == [] or answered > 0 do
      {:ok, mentions, state}
    else
      {:error, hd(errors), state}
    end
  end

  defp fetch_source(:mentions, context, state, settings, now_ms) do
    with {:ok, user_id, state} <- user_id(context, state, settings) do
      key = {:mentions, client_key(context)}

      case get(context, state, settings, "/#{user_id}/mentions",
             fields: @post_fields,
             limit: search_limit(settings),
             since: since(state, key, now_ms)
           ) do
        {:ok, body, state} ->
          posts = parse_posts(body)
          state = State.advance_cursor(state, key, newest(posts))
          {matcher, state} = matcher(context, state)

          # The feed is the account's, not the client's: keep only the
          # posts that name one of this client's brand terms.
          {:ok, Enum.filter(posts, &(Matching.clients_for(matcher, &1.text) != [])), state}

        {:error, reason, state} ->
          {:error, reason, state}
      end
    end
  end

  defp fetch_source(:replies, context, state, settings, _now_ms) do
    with {:ok, user_id, state} <- user_id(context, state, settings),
         {:ok, body, state} <-
           get(context, state, settings, "/#{user_id}/threads",
             fields: @own_post_fields,
             limit: @own_posts_limit
           ) do
      body
      |> own_posts_with_replies()
      |> Enum.reduce_while({:ok, [], state}, fn post_id, {:ok, acc, state} ->
        case get(context, state, settings, "/#{post_id}/replies",
               fields: @post_fields,
               limit: @replies_limit
             ) do
          {:ok, body, state} -> {:cont, {:ok, parse_posts(body) ++ acc, state}}
          {:error, reason, state} -> {:halt, {:error, reason, state}}
        end
      end)
    end
  end

  defp search(term, context, state, settings, now_ms) do
    case QueryBudget.remaining(state.budget, now_ms) do
      0 ->
        wait_ms = QueryBudget.wait_ms(state.budget, now_ms)
        {:error, {:quota_exhausted, wait_ms}, log_exhausted(state, wait_ms, now_ms)}

      _left ->
        key = {:search, client_key(context), String.downcase(term)}
        state = %{state | budget: QueryBudget.spend(state.budget, now_ms)}

        case get(context, state, settings, "/keyword_search",
               q: term,
               search_type: "RECENT",
               fields: @post_fields,
               limit: search_limit(settings),
               since: since(state, key, now_ms)
             ) do
          {:ok, body, state} ->
            posts = parse_posts(body)
            {:ok, posts, State.advance_cursor(state, key, newest(posts))}

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp user_id(_context, %State{user_id: user_id} = state, _settings) when is_binary(user_id),
    do: {:ok, user_id, state}

  defp user_id(context, state, settings) do
    case get(context, state, settings, "/me", fields: "id,username") do
      {:ok, %{"id" => id} = body, state} when is_binary(id) ->
        if id =~ @id_pattern do
          {:ok, id, %{state | user_id: id, username: username(body["username"])}}
        else
          {:error, :bad_user_id, state}
        end

      {:ok, _body, state} ->
        {:error, :bad_user_id, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp own_posts_with_replies(%{"data" => posts}) when is_list(posts) do
    for %{"id" => id, "has_replies" => true} <- posts, is_binary(id), id =~ @id_pattern, do: id
  end

  defp own_posts_with_replies(_body), do: []

  # One matcher per client and set of terms, built on first use.
  defp matcher(context, state) do
    key = {client_key(context), context.keywords}

    case Map.fetch(state.matchers, key) do
      {:ok, matcher} ->
        {matcher, state}

      :error ->
        client = %SmmMonitor.Client{id: "client", name: "client", keywords: context.keywords}
        matcher = Matching.build([client])
        {matcher, %{state | matchers: Map.put(state.matchers, key, matcher)}}
    end
  end

  # --- HTTP -----------------------------------------------------------------

  defp get(_context, state, settings, path, params) do
    host = Keyword.get(settings, :graph_host, @graph_host)

    [
      url: "#{host}/#{@api_version}#{path}",
      params: params ++ [access_token: state.token],
      receive_timeout: 10_000,
      # Retrying is the worker's job.
      retry: false
    ]
    |> Kernel.++(Keyword.get(settings, :req_options, []))
    |> Req.new()
    |> Req.request()
    |> handle_response(state)
  end

  defp handle_response({:ok, %{status: 200, body: body}}, state) when is_map(body),
    do: {:ok, body, state}

  defp handle_response({:ok, %{status: 200}}, state), do: {:error, :bad_response, state}

  defp handle_response({:ok, %{status: 429} = response}, state),
    do: {:error, {:rate_limited, retry_after_ms(response)}, state}

  defp handle_response({:ok, %{status: status, body: body}}, state) when status in 400..499 do
    case MetaGraph.classify(body) do
      {:expired_token, message} ->
        {:error, {:expired_access_token, message}, state}

      {{:throttled, minutes}, _message} ->
        wait_ms = if minutes, do: trunc(minutes * 60_000), else: @default_throttle_ms
        {:error, {:rate_limited, max(wait_ms, 1_000)}, state}

      {:missing_permission, message} ->
        {:error, {:missing_permission, message}, state}

      {:other, message} ->
        {:error, {:graph_error, status, message || "unknown"}, state}
    end
  end

  defp handle_response({:ok, %{status: status}}, state), do: {:error, {:http_error, status}, state}

  # Only the reason: the exception's request would carry the token.
  defp handle_response({:error, %{reason: reason}}, state),
    do: {:error, {:transport, reason}, state}

  defp handle_response({:error, _exception}, state), do: {:error, {:transport, :unknown}, state}

  defp retry_after_ms(response) do
    with [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds > 0 <- Integer.parse(String.trim(value)) do
      seconds * 1_000
    else
      _none -> @default_throttle_ms
    end
  end

  # --- mapping --------------------------------------------------------------

  defp post_to_mention(%{"id" => id} = post) when is_binary(id) do
    if id =~ @id_pattern do
      %{
        id: "threads-#{id}",
        platform: :threads,
        author: username(post["username"]) || "@unknown",
        text: if(is_binary(post["text"]), do: post["text"], else: ""),
        url: permalink(post["permalink"]),
        timestamp: if(is_binary(post["timestamp"]), do: post["timestamp"])
      }
    end
  end

  defp post_to_mention(_post), do: nil

  defp username(name) when is_binary(name) do
    if name =~ @username_pattern, do: "@" <> name
  end

  defp username(_name), do: nil

  # The newest post time in a batch, in Unix seconds.
  defp newest(posts) do
    posts
    |> Enum.map(&unix(&1.timestamp))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp unix(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _error -> nil
    end
  end

  defp unix(_timestamp), do: nil

  defp since(state, key, now_ms) do
    case State.cursor(state, key) do
      nil -> div(now_ms, 1_000) - @first_lookback_s
      seen -> seen - @overlap_s
    end
    |> max(@earliest_since)
  end

  # --- budget and logging ---------------------------------------------------

  defp log_exhausted(state, wait_ms, now_ms) do
    {already_logged?, budget} = QueryBudget.mark_exhausted_logged(state.budget)

    unless already_logged? do
      Logger.warning(
        "threads: keyword-search budget spent (#{QueryBudget.summary(budget, now_ms)}). " <>
          "Search pauses for about #{max(div(wait_ms, 60_000), 1)} min; mentions carry on."
      )
    end

    %{state | budget: budget}
  end

  # A cadence the budget can't sustain isn't an error, since the budget
  # stops it, but search would go quiet for part of every day. Said once,
  # at the first poll, when the clients are known.
  defp check_cadence(%State{cadence_checked: true} = state, _context, _settings), do: state

  defp check_cadence(state, context, settings) do
    interval_ms = Map.get(context, :interval_ms)

    with false <- SmmMonitor.mock_platform?(:threads),
         true <- :search in Sources.normalize(Keyword.get(settings, :sources)),
         true <- is_integer(interval_ms) and interval_ms > 0,
         queries_per_poll when queries_per_poll > 0 <- queries_per_poll(settings) do
      needed = div(:timer.hours(24), interval_ms) * queries_per_poll
      budget = state.budget.budget

      if needed > budget do
        sustainable_min = ceil(24 * 60 * queries_per_poll / budget)

        Logger.warning(
          "threads: polling every #{div(interval_ms, 60_000)} min searches #{needed} times a " <>
            "day (#{queries_per_poll} brand terms) but the budget is #{budget}. Search will " <>
            "stop part way through each day. Set SMM_THREADS_POLL_INTERVAL_MS to " <>
            "#{sustainable_min * 60_000} (#{sustainable_min} min) or slower."
        )
      end
    end

    %{state | cadence_checked: true}
  end

  defp queries_per_poll(settings) do
    SmmMonitor.Clients.active()
    |> Enum.map(&length(search_terms(&1.keywords, settings)))
    |> Enum.sum()
  catch
    :exit, _reason -> 0
  end

  defp describe({:missing_permission, message}),
    do: "missing permission (#{message}). Check the token has the scope this source needs"

  defp describe({:expired_access_token, _message}),
    do: "the access token has expired or been revoked. Paste a new THREADS_ACCESS_TOKEN"

  defp describe({:rate_limited, ms}), do: "Meta is throttling requests; waiting #{div(ms, 1_000)}s"
  defp describe({:graph_error, status, message}), do: "HTTP #{status}: #{message}"
  defp describe(reason), do: inspect(reason)

  defp first_reason([{:error, reason} | _rest]), do: reason
  defp first_reason(_failures), do: :unknown

  defp client_key(%{client: %{id: id}}), do: id
  defp client_key(_context), do: :default

  defp max_terms(settings) do
    case Keyword.get(settings, :max_terms, @default_max_terms) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_terms
    end
  end

  defp search_limit(settings) do
    case Keyword.get(settings, :search_limit, @default_search_limit) do
      n when is_integer(n) -> n |> max(1) |> min(100)
      _other -> @default_search_limit
    end
  end

  defp now_ms(settings) do
    case Keyword.get(settings, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _none -> System.system_time(:millisecond)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
