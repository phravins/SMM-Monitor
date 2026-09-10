defmodule SmmMonitor.Fetchers.Twitter do
  @moduledoc """
  Twitter/X fetcher — live via the X API v2 recent search endpoint.

  `GET /2/tweets/search/recent` searches the **last 7 days** of public
  posts, which is as far back as any tier below Pro can look. For brand
  monitoring that is ample: a mention nobody saw for a week is history,
  not an alert.

  ## Authentication

  App-only auth: a static **Bearer token** generated in the X Developer
  Portal, sent as `Authorization: Bearer …`. There is no refresh flow and
  no user context — the token is the whole credential — so unlike Reddit
  there is nothing to cache between polls. See the README for how to
  generate one.

  Recent search needs a **paid tier**. The free tier can post but not
  search, so without a paid token this platform stays on fixtures.

  ## Two limits, tracked separately

  X bounds this endpoint twice, and the two need different handling:

    * **Requests per 15 minutes** — reported in `x-rate-limit-*` headers,
      so it is read from responses rather than assumed
      (`Twitter.RateLimit`).
    * **Posts per month** — a Project-wide cap reported in no header, so
      it is counted locally against a conservative budget
      (`Twitter.PostBudget`).

  Both back off before the limit rather than after it, and both say so in
  the log once rather than on every poll.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.Twitter,
        max_results: 25,
        monthly_post_budget: 10_000,
        billing_cycle_day: 1

  The search terms are the shared `:keywords` setting, the same brand
  terms every other platform uses.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :twitter, display_name: "Twitter/X"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.Twitter.{PostBudget, RateLimit, State}

  @search_url "https://api.x.com/2/tweets/search/recent"

  @default_max_results 25
  @default_monthly_post_budget 10_000
  @default_billing_cycle_day 1

  # v2 allows 10..100 results per page for recent search.
  @min_results 10
  @max_results 100

  # Everything needed to render a mention: the text and time of the post,
  # and the handle of whoever wrote it (which arrives via an expansion).
  @tweet_fields "created_at,author_id,lang,public_metrics"
  @expansions "author_id"
  @user_fields "username,name"

  @impl true
  def init_state(context) do
    settings = settings(context)

    State.new(
      Keyword.get(settings, :monthly_post_budget, @default_monthly_post_budget),
      Keyword.get(settings, :billing_cycle_day, @default_billing_cycle_day)
    )
  end

  @impl true
  def ready?(%{credentials: credentials}), do: present?(credentials[:bearer_token])

  @impl true
  def fetch(context, state) do
    state = state || init_state(context)
    settings = settings(context)
    req_options = Keyword.get(settings, :req_options, [])

    post_budget = PostBudget.rollover(state.post_budget, DateTime.utc_now())
    state = %{state | post_budget: post_budget}

    with :ok <- check_post_budget(state, settings),
         :ok <- check_rate_limit(state) do
      search(context, state, settings, req_options)
    else
      {:post_budget_exhausted, wait_ms} ->
        {:error, {:quota_exhausted, wait_ms}, log_budget_exhausted(state, wait_ms)}

      {:rate_limited, wait_ms} ->
        Logger.info(
          "twitter: near the 15-minute request limit#{summary_suffix(state)}, backing off for " <>
            "#{div(wait_ms, 1_000)}s"
        )

        {:error, {:rate_limited, wait_ms}, state}
    end
  end

  @doc """
  Effective settings: module config, overridden by the platform's `:opts`.
  The override exists so tests can inject a stub transport.
  """
  @spec settings(Fetcher.context()) :: keyword()
  def settings(context) do
    :smm_monitor
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(Map.get(context, :opts) || [])
  end

  @doc """
  Builds the v2 search query from the shared keywords.

  v2 query syntax ORs terms and quotes phrases. Retweets are excluded:
  a retweet carries no new opinion, and 500 retweets of one complaint
  would read as 500 complaints on the dashboard while eating the monthly
  post cap.

      iex> alias SmmMonitor.Fetchers.Twitter
      iex> Twitter.build_query(["realoffice"])
      "(realoffice) -is:retweet"
      iex> Twitter.build_query(["realoffice", "real office"])
      ~s|(realoffice OR "real office") -is:retweet|
  """
  @spec build_query([String.t()], keyword()) :: String.t()
  def build_query(keywords, settings \\ []) do
    case Keyword.get(settings, :query) do
      query when is_binary(query) and query != "" ->
        query

      _none ->
        terms =
          keywords
          |> List.wrap()
          |> Enum.map(&(&1 |> to_string() |> String.trim()))
          |> Enum.reject(&(&1 == ""))
          |> Enum.map_join(" OR ", &quote_if_phrase/1)

        "(#{terms}) -is:retweet"
    end
  end

  @doc """
  Maps a v2 recent-search payload onto mention attrs.

  Public and pure, so it runs against a saved API response with no
  network access. Author handles arrive in `includes.users` rather than
  on the tweet, so they are indexed by id and joined here; a tweet whose
  author is missing from the expansion still becomes a mention, because
  the text is what matters and dropping it would hide a real post.
  """
  @spec parse(map() | term()) :: [map()]
  def parse(%{"data" => tweets} = body) when is_list(tweets) do
    users =
      body
      |> get_in(["includes", "users"])
      |> List.wrap()
      |> Map.new(fn user -> {user["id"], user} end)

    tweets
    |> Enum.map(&to_mention_attrs(&1, users))
    |> Enum.reject(&is_nil/1)
  end

  # A search with no matches returns `meta.result_count: 0` and no `data`
  # key at all, which is a success, not a failure.
  def parse(_body), do: []

  @doc """
  How many posts a payload consumed from the monthly cap.

  The cap counts Posts delivered, so this is the length of `data` — not
  the page size that was requested.
  """
  @spec posts_returned(map() | term()) :: non_neg_integer()
  def posts_returned(%{"data" => tweets}) when is_list(tweets), do: length(tweets)
  def posts_returned(_body), do: 0

  # --- internals ------------------------------------------------------------

  defp check_post_budget(state, settings) do
    case PostBudget.check(state.post_budget, max_results(settings), DateTime.utc_now()) do
      {:exhausted, wait_ms} -> {:post_budget_exhausted, wait_ms}
      :ok -> :ok
    end
  end

  defp check_rate_limit(state) do
    case RateLimit.check(state.rate_limit) do
      {:backoff, wait_ms} -> {:rate_limited, wait_ms}
      :ok -> :ok
    end
  end

  defp search(context, state, settings, req_options) do
    request =
      Req.new(
        [
          url: @search_url,
          params: search_params(context, settings),
          headers: [{"authorization", "Bearer #{context.credentials[:bearer_token]}"}],
          receive_timeout: 10_000,
          # Retrying is the worker's job. A blind retry of a 429 spends a
          # request we have just been told we don't have.
          retry: false
        ] ++ req_options
      )

    state = %{state | rate_limit: RateLimit.record_request(state.rate_limit)}

    request
    |> Req.request()
    |> handle_response(state)
  end

  defp search_params(context, settings) do
    [
      query: build_query(context.keywords, settings),
      max_results: max_results(settings),
      "tweet.fields": @tweet_fields,
      expansions: @expansions,
      "user.fields": @user_fields
    ]
  end

  defp handle_response({:ok, %{status: 200, body: body, headers: headers}}, state) do
    state = %{
      state
      | rate_limit: RateLimit.observe(state.rate_limit, headers),
        post_budget: PostBudget.spend(state.post_budget, posts_returned(body))
    }

    {:ok, parse(body), state}
  end

  # 401 means the bearer token is wrong or revoked. Distinct from 403 so
  # the log says which thing to go and fix.
  defp handle_response({:ok, %{status: 401}}, state) do
    {:error, :invalid_bearer_token, state}
  end

  # 403 on this endpoint almost always means the token is valid but the
  # access tier doesn't include recent search — the free tier's shape.
  defp handle_response({:ok, %{status: 403, body: body}}, state) do
    {:error, {:forbidden, x_error_detail(body)}, state}
  end

  defp handle_response({:ok, %{status: 429, headers: headers, body: body}}, state) do
    rate_limit = RateLimit.observe(state.rate_limit, headers)
    state = %{state | rate_limit: rate_limit}

    if monthly_cap?(body) do
      # A monthly-cap 429 doesn't clear at the next window, so treat it as
      # the cap being spent and believe X over our own count.
      wait_ms = PostBudget.ms_until_reset(state.post_budget, DateTime.utc_now())

      Logger.warning(
        "twitter: X reports the monthly post cap is spent - our own count said " <>
          "#{PostBudget.summary(state.post_budget)}. Standing down until the cap resets."
      )

      {:error, {:quota_exhausted, wait_ms}, exhaust_post_budget(state)}
    else
      wait_ms = RateLimit.ms_until_reset(rate_limit) || :timer.minutes(15)

      Logger.info(
        "twitter: rate limited by X#{summary_suffix(state)}, waiting #{div(wait_ms, 1_000)}s " <>
          "for the window to reset"
      )

      {:error, {:rate_limited, wait_ms}, state}
    end
  end

  defp handle_response({:ok, %{status: status}}, state) do
    {:error, {:http_error, status}, state}
  end

  defp handle_response({:error, reason}, state) do
    {:error, {:transport, reason}, state}
  end

  defp to_mention_attrs(%{"id" => id} = tweet, users) when is_binary(id) do
    user = Map.get(users, tweet["author_id"], %{})

    %{
      id: "twitter-#{id}",
      platform: :twitter,
      author: author(user),
      text: tweet["text"] || "",
      url: status_url(user, id),
      timestamp: tweet["created_at"]
    }
  end

  # No id means no stable identity and no link; dropping it is better than
  # storing a mention that can't be de-duplicated or opened.
  defp to_mention_attrs(_tweet, _users), do: nil

  defp author(%{"username" => username}) when is_binary(username) and username != "",
    do: "@" <> username

  defp author(_user), do: "@unknown"

  # x.com/i/web/status/:id resolves for any tweet, so it works even when
  # the author expansion is missing; the handle form is nicer when we have it.
  defp status_url(%{"username" => username}, id) when is_binary(username) and username != "",
    do: "https://x.com/#{username}/status/#{id}"

  defp status_url(_user, id), do: "https://x.com/i/web/status/#{id}"

  # Logged once per cycle, not on every poll while standing down.
  defp log_budget_exhausted(state, wait_ms) do
    {already_logged?, post_budget} = PostBudget.mark_exhausted_logged(state.post_budget)

    unless already_logged? do
      Logger.warning(
        "twitter: monthly post budget spent (#{PostBudget.summary(post_budget)}). Pausing " <>
          "polling for #{div(wait_ms, 3_600_000)}h, until the billing cycle resets. Raise " <>
          "SMM_TWITTER_MONTHLY_POST_BUDGET if your plan allows more."
      )
    end

    %{state | post_budget: post_budget}
  end

  defp exhaust_post_budget(state) do
    post_budget = %{state.post_budget | used: state.post_budget.budget}
    {_logged?, post_budget} = PostBudget.mark_exhausted_logged(post_budget)
    %{state | post_budget: post_budget}
  end

  # X signals the monthly cap with a 429 whose body mentions usage caps,
  # rather than with a distinct status. Matching on the text is unlovely
  # but it is what distinguishes "wait 15 minutes" from "wait 3 weeks".
  defp monthly_cap?(body) when is_map(body) do
    body
    |> x_error_detail()
    |> to_string()
    |> String.downcase()
    |> String.contains?("usage cap")
  end

  defp monthly_cap?(body) when is_binary(body) do
    String.contains?(String.downcase(body), "usage cap")
  end

  defp monthly_cap?(_body), do: false

  defp x_error_detail(%{"detail" => detail}) when is_binary(detail), do: detail
  defp x_error_detail(%{"title" => title}) when is_binary(title), do: title

  defp x_error_detail(%{"errors" => [%{"message" => message} | _rest]}) when is_binary(message),
    do: message

  defp x_error_detail(_body), do: nil

  defp summary_suffix(state) do
    case RateLimit.summary(state.rate_limit) do
      nil -> ""
      summary -> " (#{summary})"
    end
  end

  defp max_results(settings) do
    settings
    |> Keyword.get(:max_results, @default_max_results)
    |> min(@max_results)
    |> max(@min_results)
  end

  defp quote_if_phrase(keyword) do
    if String.contains?(keyword, " "), do: ~s("#{keyword}"), else: keyword
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
