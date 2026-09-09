defmodule SmmMonitor.Fetchers.Reddit do
  @moduledoc """
  Reddit fetcher.

  Uses the free application-only OAuth flow: exchange the script app's
  client id/secret for a token, then search `/search` sorted by new. Reddit
  is a good first real platform because the free tier is generous and the
  payload maps onto `SmmMonitor.Mention` almost directly.

  Credentials (see `.env.example`):

      REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_USER_AGENT

  Without them the worker keeps this platform in mock mode.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :reddit, display_name: "Reddit"

  require Logger

  @token_url "https://www.reddit.com/api/v1/access_token"
  @search_url "https://oauth.reddit.com/search"
  @limit 25

  @impl true
  def ready?(%{credentials: credentials}) do
    is_binary(credentials[:client_id]) and is_binary(credentials[:client_secret])
  end

  @impl true
  def fetch(context, state) do
    with {:ok, token} <- access_token(context),
         {:ok, body} <- search(token, context) do
      {:ok, parse(body), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp access_token(%{credentials: credentials}) do
    request =
      Req.new(
        url: @token_url,
        method: :post,
        auth: {:basic, "#{credentials[:client_id]}:#{credentials[:client_secret]}"},
        form: [grant_type: "client_credentials"],
        headers: [{"user-agent", credentials[:user_agent] || "smm_monitor/0.1"}],
        receive_timeout: 10_000
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: status, body: body}} -> {:error, {:auth_failed, status, body}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp search(token, %{keywords: keywords, credentials: credentials, opts: opts}) do
    request =
      Req.new(
        url: @search_url,
        params: [
          q: Enum.join(keywords, " OR "),
          sort: "new",
          limit: Keyword.get(opts, :limit, @limit),
          type: "link",
          restrict_sr: false
        ],
        headers: [
          {"authorization", "Bearer #{token}"},
          {"user-agent", credentials[:user_agent] || "smm_monitor/0.1"}
        ],
        receive_timeout: 10_000
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  Maps a Reddit listing payload onto mention attrs.

  Public so it can be exercised against a saved payload without HTTP.
  """
  @spec parse(map()) :: [map()]
  def parse(%{"data" => %{"children" => children}}) when is_list(children) do
    Enum.map(children, fn %{"data" => post} ->
      %{
        id: "reddit-#{post["id"]}",
        platform: :reddit,
        author: "u/#{post["author"]}",
        text: text_of(post),
        url: "https://reddit.com#{post["permalink"]}",
        timestamp: trunc(post["created_utc"] || 0)
      }
    end)
  end

  def parse(_body), do: []

  # Reddit posts are a title plus optional selftext; the title alone is
  # usually the mention, so keep it first and trim the body.
  defp text_of(post) do
    [post["title"], post["selftext"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" — ")
    |> String.slice(0, 500)
  end
end
