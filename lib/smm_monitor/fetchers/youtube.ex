defmodule SmmMonitor.Fetchers.YouTube do
  @moduledoc """
  YouTube fetcher.

  Uses Data API v3 `search.list` with a plain API key — no OAuth dance,
  which makes it the other easy free-tier platform. Note the API's quota is
  per-day and `search.list` is expensive (100 units a call), so a 30s poll
  is already close to the free quota; raise `SMM_POLL_INTERVAL_MS` if you
  run this live for long.

  Credentials: `YOUTUBE_API_KEY`.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :youtube, display_name: "YouTube"

  @search_url "https://www.googleapis.com/youtube/v3/search"
  @max_results 25

  @impl true
  def ready?(%{credentials: credentials}), do: is_binary(credentials[:api_key])

  @impl true
  def fetch(%{keywords: keywords, credentials: credentials, opts: opts}) do
    request =
      Req.new(
        url: @search_url,
        params: [
          part: "snippet",
          q: Enum.join(keywords, " | "),
          type: "video",
          order: "date",
          maxResults: Keyword.get(opts, :max_results, @max_results),
          key: credentials[:api_key]
        ],
        receive_timeout: 10_000
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse(body)}
      {:ok, %{status: 403, body: body}} -> {:error, {:quota_or_forbidden, body}}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc "Maps a `search.list` payload onto mention attrs."
  @spec parse(map()) :: [map()]
  def parse(%{"items" => items}) when is_list(items) do
    items
    |> Enum.filter(&match?(%{"id" => %{"videoId" => _id}}, &1))
    |> Enum.map(fn %{"id" => %{"videoId" => video_id}, "snippet" => snippet} ->
      %{
        id: "youtube-#{video_id}",
        platform: :youtube,
        author: snippet["channelTitle"] || "unknown channel",
        text: text_of(snippet),
        url: "https://www.youtube.com/watch?v=#{video_id}",
        timestamp: snippet["publishedAt"]
      }
    end)
  end

  def parse(_body), do: []

  defp text_of(snippet) do
    [snippet["title"], snippet["description"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" — ")
    |> String.slice(0, 500)
  end
end
