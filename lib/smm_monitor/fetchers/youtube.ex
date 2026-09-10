defmodule SmmMonitor.Fetchers.YouTube do
  @moduledoc """
  YouTube fetcher — live via the Data API v3.

  Authentication is a plain API key in the query string: the data we want
  is public, so there is no OAuth flow. See the README for how to create
  one in the Google Cloud Console.

  ## Why `search.list` and not `commentThreads.list`

  For brand monitoring, `search.list` is the only endpoint that can
  *discover* a mention. `commentThreads.list` is far cheaper (1 unit
  against search's 100) and comments are where brand chatter really
  lives — but it can only read comments on a video or channel you already
  name. Its `searchTerms` parameter filters *within* those, so it cannot
  answer "who mentioned us anywhere on YouTube today", which is the
  question this tool exists to answer.

  The natural next step is a hybrid: keep `search.list` for discovery, and
  spend 1 unit per discovered video on `commentThreads.list` to pull the
  discussion underneath it. That is a meaningful feature rather than a
  tweak, so it is left for later; see the README.

  ## Quota

  The free tier is 10,000 units a day and a search costs 100, so the
  budget is 100 searches a day — the binding constraint on how often this
  can poll. `SmmMonitor.Fetchers.YouTube.Quota` tracks the spend and
  stands the platform down when a conservative budget is reached, rather
  than letting every call fail once Google cuts us off.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.YouTube,
        max_results: 25,
        order: "date",
        daily_quota_budget: 8_000,
        published_within_ms: :timer.hours(24)

  The search terms are the shared `:keywords` setting — the same brand
  terms Reddit uses — not a YouTube-specific one.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :youtube, display_name: "YouTube"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.YouTube.{Quota, State}

  @search_url "https://www.googleapis.com/youtube/v3/search"

  @default_max_results 25
  @default_order "date"
  @default_budget 8_000
  # Only look at videos published recently; older ones have been seen.
  @default_published_within_ms :timer.hours(24)

  # The API caps a page at 50.
  @max_results_ceiling 50

  @impl true
  def init_state(context) do
    budget = Keyword.get(settings(context), :daily_quota_budget, @default_budget)
    warn_if_cadence_unaffordable(context, budget)
    State.new(budget)
  end

  @impl true
  def ready?(%{credentials: credentials}), do: present?(credentials[:api_key])

  @impl true
  def fetch(context, state) do
    state = state || init_state(context)
    settings = settings(context)
    req_options = Keyword.get(settings, :req_options, [])

    quota = Quota.rollover(state.quota, DateTime.utc_now())
    state = %{state | quota: quota}

    case Quota.check(quota, Quota.search_cost()) do
      {:exhausted, wait_ms} ->
        {:error, {:quota_exhausted, wait_ms}, log_exhausted(state, wait_ms)}

      :ok ->
        search(context, state, settings, req_options)
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
  Builds the search query from the shared keywords.

  YouTube's search syntax uses `|` for OR and quotes for phrases.

      iex> alias SmmMonitor.Fetchers.YouTube
      iex> YouTube.build_query(["realoffice"])
      "realoffice"
      iex> YouTube.build_query(["realoffice", "real office"])
      ~s(realoffice | "real office")
  """
  @spec build_query([String.t()]) :: String.t()
  def build_query(keywords) do
    keywords
    |> List.wrap()
    |> Enum.reject(&(String.trim(to_string(&1)) == ""))
    |> Enum.map_join(" | ", &quote_if_phrase/1)
  end

  @doc """
  Maps a `search.list` payload onto mention attrs.

  Public and pure, so it can be run against a saved API response with no
  network access. `search.list` also returns channels and playlists; only
  videos carry a `videoId` and only those become mentions.
  """
  @spec parse(map() | term()) :: [map()]
  def parse(%{"items" => items}) when is_list(items) do
    items
    |> Enum.map(&to_mention_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_body), do: []

  # --- internals ------------------------------------------------------------

  defp search(context, state, settings, req_options) do
    request =
      Req.new(
        [
          url: @search_url,
          params: search_params(context, settings),
          receive_timeout: 10_000,
          # Retrying is the worker's job. Every retry of a search costs
          # another 100 quota units, which is the last thing we want when
          # the failure is Google telling us the quota is gone.
          retry: false
        ] ++ req_options
      )

    # Spend the units before the call: a request that reaches Google counts
    # against the quota whether or not we like the response.
    state = %{state | quota: Quota.spend(state.quota, Quota.search_cost())}

    request
    |> Req.request()
    |> handle_response(state)
  end

  defp search_params(context, settings) do
    [
      part: "snippet",
      q: build_query(context.keywords),
      type: "video",
      order: Keyword.get(settings, :order, @default_order),
      maxResults: max_results(settings),
      publishedAfter: published_after(settings),
      key: context.credentials[:api_key]
    ]
  end

  defp handle_response({:ok, %{status: 200, body: body}}, state) do
    {:ok, parse(body), state}
  end

  # Google returns 403 both for a quota overrun and for a key that isn't
  # allowed to call the API. Telling them apart matters: one resolves
  # itself overnight, the other needs the key fixing.
  defp handle_response({:ok, %{status: 403, body: body}}, state) do
    case google_reason(body) do
      reason when reason in ["quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded"] ->
        wait_ms = Quota.ms_until_reset(DateTime.utc_now())

        Logger.warning(
          "youtube: Google reports the API quota is spent (#{reason}) - our own count said " <>
            "#{Quota.summary(state.quota)}. Standing down until the quota resets."
        )

        # Believe Google over our own estimate: something else is sharing
        # this key, so stop until the reset rather than keep paying to fail.
        {:error, {:quota_exhausted, wait_ms}, exhaust_local_budget(state)}

      reason ->
        {:error, {:forbidden, reason || :unknown}, state}
    end
  end

  defp handle_response({:ok, %{status: 400, body: body}}, state) do
    {:error, {:bad_request, google_reason(body) || :unknown}, state}
  end

  defp handle_response({:ok, %{status: status}}, state) do
    {:error, {:http_error, status}, state}
  end

  defp handle_response({:error, reason}, state) do
    {:error, {:transport, reason}, state}
  end

  defp to_mention_attrs(%{"id" => %{"videoId" => video_id}, "snippet" => snippet})
       when is_binary(video_id) and is_map(snippet) do
    %{
      id: "youtube-#{video_id}",
      platform: :youtube,
      author: channel(snippet),
      text: text_of(snippet),
      url: "https://www.youtube.com/watch?v=#{video_id}",
      timestamp: snippet["publishedAt"]
    }
  end

  # Channels and playlists have no videoId; skip them rather than storing
  # a mention that can't be opened.
  defp to_mention_attrs(_item), do: nil

  defp channel(snippet) do
    case snippet["channelTitle"] do
      title when is_binary(title) and title != "" -> title
      _missing -> "unknown channel"
    end
  end

  defp text_of(snippet) do
    [snippet["title"], snippet["description"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" — ")
    |> String.slice(0, 500)
  end

  # A poll interval faster than the budget can sustain isn't an error — the
  # quota cutoff handles it — but it does mean the platform goes dark part
  # way through each day, which is worth saying out loud at startup rather
  # than leaving someone to notice the gap in their dashboard.
  defp warn_if_cadence_unaffordable(context, budget) do
    interval_ms = Map.get(context, :interval_ms)

    with false <- SmmMonitor.mock_platform?(:youtube),
         true <- is_integer(interval_ms) and interval_ms > 0 do
      cost = Quota.search_cost()
      polls_per_day = div(:timer.hours(24), interval_ms)
      needed = polls_per_day * cost

      if needed > budget do
        affordable = div(budget, cost)
        coverage_h = Float.round(affordable * interval_ms / 3_600_000, 1)
        sustainable_min = div(div(:timer.hours(24), max(affordable, 1)), 60_000)

        Logger.warning(
          "youtube: polling every #{div(interval_ms, 60_000)} min needs #{needed} quota " <>
            "units/day but the budget is #{budget}. Coverage will stop after about " <>
            "#{coverage_h}h each day. Set SMM_YOUTUBE_POLL_INTERVAL_MS to " <>
            "#{sustainable_min * 60_000} (#{sustainable_min} min) or slower for full-day coverage."
        )
      end
    end
  end

  # Logged once per quota day, not on every poll while we're standing down.
  defp log_exhausted(state, wait_ms) do
    {already_logged?, quota} = Quota.mark_exhausted_logged(state.quota)

    unless already_logged? do
      Logger.warning(
        "youtube: daily quota budget spent (#{Quota.summary(quota)}). Pausing polling for " <>
          "#{div(wait_ms, 60_000)} minutes, until the quota resets at midnight Pacific."
      )
    end

    %{state | quota: quota}
  end

  # Google says we're out even though our count disagrees — trust Google.
  defp exhaust_local_budget(state) do
    quota = %{state.quota | used: state.quota.budget}
    {_logged?, quota} = Quota.mark_exhausted_logged(quota)
    %{state | quota: quota}
  end

  defp google_reason(%{"error" => %{"errors" => [%{"reason" => reason} | _rest]}}), do: reason
  defp google_reason(%{"error" => %{"status" => status}}) when is_binary(status), do: status
  defp google_reason(_body), do: nil

  defp max_results(settings) do
    settings
    |> Keyword.get(:max_results, @default_max_results)
    |> min(@max_results_ceiling)
    |> max(1)
  end

  defp published_after(settings) do
    window = Keyword.get(settings, :published_within_ms, @default_published_within_ms)

    DateTime.utc_now()
    |> DateTime.add(-window, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp quote_if_phrase(keyword) do
    keyword = String.trim(to_string(keyword))
    if String.contains?(keyword, " "), do: ~s("#{keyword}"), else: keyword
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
