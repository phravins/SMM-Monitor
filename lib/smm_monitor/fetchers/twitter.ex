defmodule SmmMonitor.Fetchers.Twitter do
  @moduledoc """
  Twitter/X fetcher — **stubbed**.

  Recent-search (`GET /2/tweets/search/recent`) needs a paid Basic tier or
  above; there is no free read tier to develop against. So this module ships
  as a mock-only platform: the tab, the counts and the sentiment bar all
  work, and the HTTP call is the only missing piece.

  To finish it:

    1. set `TWITTER_BEARER_TOKEN` (Basic tier or above),
    2. make `ready?/1` check for that token instead of returning false,
    3. implement `fetch/1` against
       `https://api.twitter.com/2/tweets/search/recent`, requesting
       `tweet.fields=created_at,author_id` and `expansions=author_id`,
    4. map the payload with `parse/1` below, which is already written
       against the documented v2 response shape.

  Everything else — polling, supervision, sentiment, storage, the TUI — is
  already wired and needs no changes.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :twitter, display_name: "Twitter/X"

  # Deliberately false: without a paid token there is nothing to try, and
  # the worker falls back to fixtures rather than logging failures forever.
  @impl true
  def ready?(_context), do: false

  @impl true
  def fetch(_context), do: {:error, :requires_paid_api_access}

  @doc """
  Maps a v2 recent-search payload onto mention attrs.

  Written ahead of `fetch/1` so the mapping is reviewable (and testable)
  before anyone pays for a token.
  """
  @spec parse(map()) :: [map()]
  def parse(%{"data" => tweets} = body) when is_list(tweets) do
    users =
      body
      |> get_in(["includes", "users"])
      |> List.wrap()
      |> Map.new(fn user -> {user["id"], user["username"]} end)

    Enum.map(tweets, fn tweet ->
      %{
        id: "twitter-#{tweet["id"]}",
        platform: :twitter,
        author: "@" <> Map.get(users, tweet["author_id"], "unknown"),
        text: tweet["text"] || "",
        url: "https://twitter.com/i/web/status/#{tweet["id"]}",
        timestamp: tweet["created_at"]
      }
    end)
  end

  def parse(_body), do: []
end
