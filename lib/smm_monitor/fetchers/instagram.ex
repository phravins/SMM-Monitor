defmodule SmmMonitor.Fetchers.Instagram do
  @moduledoc """
  Instagram fetcher — live via the Instagram Graph API.

  ## Read this before trusting the Instagram tab

  **Instagram has no keyword search.** Reddit, YouTube and X will all
  answer "who mentioned this brand anywhere on the platform?". The
  Instagram Graph API will not, at any tier, for any amount of money.
  There is no endpoint that takes a word and returns public posts
  containing it.

  What it offers instead is a handful of narrow, account-scoped views,
  and this fetcher implements the ones that can be polled:

    * **`:tags`** — media where the connected business account was
      @-tagged by someone else. The closest pollable thing to inbound
      brand mentions.
    * **`:comments`** — comments on the account's *own* media, where
      complaints and questions actually accumulate.
    * **`:hashtag`** — public media carrying a tracked hashtag. The only
      source that reaches accounts with no relationship to yours, and the
      one Meta limits hardest: 30 unique hashtags per rolling 7 days, a
      24-hour window, and **no author** — usernames are stripped from
      hashtag results, so these arrive attributed to the hashtag.

  What no source covers: an @-mention of the brand in someone else's
  caption or comment where the account was not tagged in the media.
  Meta delivers those **only by webhook**, a push to a public HTTPS
  endpoint. A polling tool on a private box cannot see them. That is a
  limit of the platform, not of this code, and the README says so.

  ## Requirements

  An Instagram **Business or Creator** account, linked to a Facebook
  Page, and a Meta app with the Instagram Graph API product added. The
  token needs `instagram_basic`, `instagram_manage_comments` and
  `pages_read_engagement`; hashtag search additionally requires the
  account id on every call. See the README for the full walkthrough.

  ## Partial failure is normal

  Meta's permissions are granular, and a token that can read tags often
  cannot read comments. So each source runs independently: one failing
  is logged and the others still return mentions. Only a poll where
  *every* source failed is reported as an error.

  ## Configuration

      config :smm_monitor, SmmMonitor.Fetchers.Instagram,
        sources: [:tags, :comments],
        hashtags: ["realoffice"],
        media_limit: 10,
        result_limit: 25
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :instagram, display_name: "Instagram"

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.Fetchers.Instagram.{Sources, State, Throttle}

  @graph_host "https://graph.facebook.com"
  @api_version "v21.0"

  @default_media_limit 10
  @default_result_limit 25

  # Fields on an IG Media object. `username` is available here — it is
  # only hashtag results that strip it.
  @media_fields "id,caption,permalink,timestamp,media_type,username"
  @comment_fields "id,text,timestamp,username"
  # Hashtag results carry no username, by design: Meta returns no
  # personally identifying information from hashtag search.
  @hashtag_media_fields "id,caption,permalink,timestamp,media_type"

  @impl true
  def init_state(_context), do: State.new()

  @impl true
  def ready?(%{credentials: credentials}) do
    # Both are required: every endpoint here is scoped to one account, so
    # a token with no account id can't address anything.
    present?(credentials[:access_token]) and present?(business_account_id(credentials))
  end

  @impl true
  def fetch(context, state) do
    state = state || State.new()
    settings = settings(context)

    case Throttle.check(state.throttle) do
      {:backoff, wait_ms} ->
        Logger.info(
          "instagram: Meta's rate limit is close#{summary_suffix(state)}, backing off for " <>
            "#{div(wait_ms, 1_000)}s"
        )

        {:error, {:rate_limited, wait_ms}, state}

      :ok ->
        collect(context, state, settings)
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
  The hashtags to search, from config or derived from the brand keywords.

  Instagram hashtags carry no spaces, so a multi-word brand term becomes
  a single tag — "real office" is `#realoffice`, which is what people
  actually type.

      iex> alias SmmMonitor.Fetchers.Instagram
      iex> Instagram.hashtags(["realoffice", "real office"], [])
      ["realoffice"]
      iex> Instagram.hashtags(["ignored"], hashtags: ["#realofficeapp"])
      ["realofficeapp"]
  """
  @spec hashtags([String.t()], keyword()) :: [String.t()]
  def hashtags(keywords, settings) do
    case Keyword.get(settings, :hashtags) do
      configured when is_list(configured) and configured != [] -> configured
      _none -> keywords
    end
    |> Enum.map(&normalize_hashtag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Maps a `/tags` or `/media` payload onto mention attrs.

  Public and pure, so it runs against a saved API response with no
  network access.
  """
  @spec parse_media(map() | term()) :: [map()]
  def parse_media(%{"data" => media}) when is_list(media) do
    media
    |> Enum.map(&media_to_mention/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse_media(_body), do: []

  @doc """
  Maps comments out of a `/media?fields=...,comments{...}` payload.

  Comments arrive nested under the media they belong to, which is how
  they are fetched: one request with a field expansion rather than one
  request per post. The parent's permalink comes along because a comment
  has no link of its own.
  """
  @spec parse_comments(map() | term()) :: [map()]
  def parse_comments(%{"data" => media}) when is_list(media) do
    Enum.flat_map(media, fn item ->
      permalink = item["permalink"]

      item
      |> get_in(["comments", "data"])
      |> List.wrap()
      |> Enum.map(&comment_to_mention(&1, permalink))
      |> Enum.reject(&is_nil/1)
    end)
  end

  def parse_comments(_body), do: []

  @doc """
  Maps a hashtag `recent_media` payload onto mention attrs.

  Separate from `parse_media/1` for one reason: these carry no author.
  Meta strips usernames from hashtag results, so they are attributed to
  the hashtag itself rather than to a fabricated "unknown" user.
  """
  @spec parse_hashtag_media(map() | term(), String.t()) :: [map()]
  def parse_hashtag_media(%{"data" => media}, hashtag) when is_list(media) do
    media
    |> Enum.map(&hashtag_media_to_mention(&1, hashtag))
    |> Enum.reject(&is_nil/1)
  end

  def parse_hashtag_media(_body, _hashtag), do: []

  # --- internals ------------------------------------------------------------

  defp collect(context, state, settings) do
    sources = Sources.normalize(Keyword.get(settings, :sources))

    {results, state} =
      Enum.map_reduce(sources, state, fn source, acc ->
        run_source(source, context, acc, settings)
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _mentions}, &1))
    mentions = successes |> Enum.flat_map(fn {:ok, mentions} -> mentions end) |> dedupe()

    cond do
      sources == [] ->
        {:error, :no_sources_enabled, state}

      # Every source failed: there is nothing to report but the failure.
      length(failures) == length(sources) and failures != [] ->
        {:error, first_reason(failures), state}

      true ->
        {:ok, mentions, state}
    end
  end

  defp run_source(source, context, state, settings) do
    case do_fetch_source(source, context, state, settings) do
      {:ok, mentions, state} ->
        {{:ok, mentions}, state}

      {:error, reason, state} ->
        # One source failing is ordinary — a token that can read tags
        # often can't read comments — so it is logged and the poll goes on.
        Logger.warning(
          "instagram: #{source} (#{Sources.describe(source)}) failed: #{inspect(reason)}"
        )

        {{:error, reason}, state}
    end
  end

  defp do_fetch_source(:tags, context, state, settings) do
    account_id = business_account_id(context.credentials)

    case get(context, state, settings, "/#{account_id}/tags",
           fields: @media_fields,
           limit: result_limit(settings)
         ) do
      {:ok, body, state} -> {:ok, parse_media(body), state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp do_fetch_source(:comments, context, state, settings) do
    account_id = business_account_id(context.credentials)

    # One request, not one per post: Graph API field expansion pulls the
    # comments back nested inside the media they belong to.
    fields = "#{@media_fields},comments{#{@comment_fields}}"

    case get(context, state, settings, "/#{account_id}/media",
           fields: fields,
           limit: media_limit(settings)
         ) do
      {:ok, body, state} -> {:ok, parse_comments(body), state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp do_fetch_source(:hashtag, context, state, settings) do
    tags = hashtags(context.keywords, settings)

    {results, state} =
      Enum.map_reduce(tags, state, fn hashtag, acc ->
        fetch_hashtag(hashtag, context, acc, settings)
      end)

    case Enum.split_with(results, &(elem(&1, 0) == :ok)) do
      {[], [{:error, reason} | _rest]} -> {:error, reason, state}
      {oks, _errors} -> {:ok, Enum.flat_map(oks, &elem(&1, 1)), state}
    end
  end

  defp fetch_hashtag(hashtag, context, state, settings) do
    case hashtag_id(hashtag, context, state, settings) do
      {:ok, id, state} ->
        account_id = business_account_id(context.credentials)

        case get(context, state, settings, "/#{id}/recent_media",
               user_id: account_id,
               fields: @hashtag_media_fields,
               limit: result_limit(settings)
             ) do
          {:ok, body, state} -> {{:ok, parse_hashtag_media(body, hashtag)}, state}
          {:error, reason, state} -> {{:error, reason}, state}
        end

      {:error, reason, state} ->
        {{:error, reason}, state}
    end
  end

  # Ids are stable, so resolving one is a per-worker-lifetime cost rather
  # than a per-poll one.
  defp hashtag_id(hashtag, context, state, settings) do
    case State.hashtag_id(state, hashtag) do
      nil -> resolve_hashtag_id(hashtag, context, state, settings)
      id -> {:ok, id, state}
    end
  end

  defp resolve_hashtag_id(hashtag, context, state, settings) do
    account_id = business_account_id(context.credentials)

    case get(context, state, settings, "/ig_hashtag_search",
           user_id: account_id,
           q: hashtag
         ) do
      {:ok, %{"data" => [%{"id" => id} | _rest]}, state} when is_binary(id) ->
        {:ok, id, State.put_hashtag_id(state, hashtag, id)}

      {:ok, _body, state} ->
        {:error, {:unknown_hashtag, hashtag}, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp get(context, state, settings, path, params) do
    req_options = Keyword.get(settings, :req_options, [])

    request =
      Req.new(
        [
          url: "#{@graph_host}/#{@api_version}#{path}",
          params: params ++ [access_token: context.credentials[:access_token]],
          receive_timeout: 10_000,
          # Retrying is the worker's job; a retried call still counts
          # against Meta's hourly allowance.
          retry: false
        ] ++ req_options
      )

    request
    |> Req.request()
    |> handle_response(state)
  end

  defp handle_response({:ok, %{status: 200, body: body, headers: headers}}, state) do
    {:ok, body, %{state | throttle: Throttle.observe(state.throttle, headers)}}
  end

  defp handle_response({:ok, %{status: status, body: body, headers: headers}}, state)
       when status in [400, 401, 403] do
    state = %{state | throttle: Throttle.observe(state.throttle, headers)}
    error = graph_error(body)

    cond do
      # 190/463: the long-lived token has passed its 60 days. This is the
      # single most common way an Instagram integration stops working, so
      # it gets its own error rather than a generic 400.
      expired_token?(error) ->
        {:error, {:expired_access_token, error["message"]}, state}

      # 4 and 32 are Meta's throttling codes; 613 is a per-edge limit.
      throttled?(error) ->
        minutes = get_in(error, ["error_data", "estimated_time_to_regain_access"])

        {:error, :rate_limited_by_meta,
         %{state | throttle: Throttle.block(state.throttle, minutes)}}

      # 10 and 200..299 are permission errors: the token is fine but this
      # edge isn't granted. Naming the missing scope saves an afternoon.
      permission_error?(error) ->
        {:error, {:missing_permission, error["message"]}, state}

      true ->
        {:error, {:graph_error, status, error["message"] || "unknown"}, state}
    end
  end

  defp handle_response({:ok, %{status: 429, headers: headers}}, state) do
    state = %{state | throttle: Throttle.block(state.throttle, nil)}
    {:error, :rate_limited_by_meta, %{state | throttle: Throttle.observe(state.throttle, headers)}}
  end

  defp handle_response({:ok, %{status: status}}, state) do
    {:error, {:http_error, status}, state}
  end

  defp handle_response({:error, reason}, state) do
    {:error, {:transport, reason}, state}
  end

  defp media_to_mention(%{"id" => id} = media) when is_binary(id) do
    %{
      id: "instagram-#{id}",
      platform: :instagram,
      author: author(media["username"]),
      text: media["caption"] || "",
      url: media["permalink"],
      timestamp: media["timestamp"]
    }
  end

  defp media_to_mention(_media), do: nil

  defp comment_to_mention(%{"id" => id} = comment, permalink) when is_binary(id) do
    %{
      # Namespaced so a comment id can never collide with a media id.
      id: "instagram-comment-#{id}",
      platform: :instagram,
      author: author(comment["username"]),
      text: comment["text"] || "",
      # A comment has no permalink of its own; the post it sits under is
      # where you go to read it.
      url: permalink,
      timestamp: comment["timestamp"]
    }
  end

  defp comment_to_mention(_comment, _permalink), do: nil

  defp hashtag_media_to_mention(%{"id" => id} = media, hashtag) when is_binary(id) do
    %{
      id: "instagram-#{id}",
      platform: :instagram,
      # Meta returns no username for hashtag results. Saying "#realoffice"
      # is honest; inventing "@unknown" would imply we looked and failed.
      author: "##{hashtag}",
      text: media["caption"] || "",
      url: media["permalink"],
      timestamp: media["timestamp"]
    }
  end

  defp hashtag_media_to_mention(_media, _hashtag), do: nil

  # The same post can arrive from two sources — tagged *and* carrying the
  # hashtag — and the processing layer would treat them as one anyway.
  defp dedupe(mentions), do: Enum.uniq_by(mentions, & &1.id)

  defp first_reason([{:error, reason} | _rest]), do: reason
  defp first_reason(_failures), do: :unknown

  defp author(username) when is_binary(username) and username != "", do: "@" <> username
  defp author(_username), do: "@unknown"

  defp graph_error(%{"error" => %{} = error}), do: error
  defp graph_error(_body), do: %{}

  defp expired_token?(%{"code" => 190}), do: true
  defp expired_token?(%{"error_subcode" => subcode}) when subcode in [463, 467], do: true
  defp expired_token?(_error), do: false

  defp throttled?(%{"code" => code}) when code in [4, 17, 32, 613], do: true
  defp throttled?(_error), do: false

  defp permission_error?(%{"code" => 10}), do: true
  defp permission_error?(%{"code" => code}) when code in 200..299, do: true
  defp permission_error?(_error), do: false

  defp summary_suffix(state) do
    case Throttle.summary(state.throttle) do
      nil -> ""
      summary -> " (#{summary})"
    end
  end

  # INSTAGRAM_USER_ID is the older name for the same value; both work.
  defp business_account_id(credentials) do
    credentials[:business_account_id] || credentials[:user_id]
  end

  defp normalize_hashtag(keyword) do
    keyword
    |> to_string()
    |> String.trim()
    |> String.trim_leading("#")
    |> String.replace(~r/[^\p{L}\p{N}_]/u, "")
    |> String.downcase()
  end

  defp media_limit(settings) do
    settings |> Keyword.get(:media_limit, @default_media_limit) |> min(50) |> max(1)
  end

  defp result_limit(settings) do
    settings |> Keyword.get(:result_limit, @default_result_limit) |> min(50) |> max(1)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
