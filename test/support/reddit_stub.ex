defmodule SmmMonitor.RedditStub do
  @moduledoc """
  A stub HTTP transport for the Reddit fetcher, so tests can exercise the
  real fetch path without touching the network.

  Req runs its adapter in the calling process, so the script and the
  recorded requests live in that process's dictionary — no shared state
  between tests, and no extra dependency.

      RedditStub.install(search: RedditStub.listing(fixture))
      Reddit.fetch(context, state)
      assert [{:post, token_url}, {:get, search_url}] = RedditStub.requests()

  Responses are given per request kind: `:token`, `:search`, or the
  subreddit listings `:new` and `:comments`. A list is consumed in order
  and the last entry repeats, which is what lets a test script "401
  first, then 200". A function is called with the request URL, for a
  response that depends on which subreddits were asked for.
  """

  @key :reddit_stub

  @doc "Installs a script for this process. See the moduledoc."
  def install(script) do
    script = Map.new(script, fn {kind, responses} -> {kind, List.wrap(responses)} end)
    Process.put(@key, %{script: script, requests: []})
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc "The requests made so far, oldest first, as `{method, url}`."
  def requests do
    case Process.get(@key) do
      nil -> []
      %{requests: requests} -> Enum.reverse(requests)
    end
  end

  @doc "Requests made against the token endpoint."
  def token_requests, do: Enum.filter(requests(), fn {_method, url} -> token_url?(url) end)

  @doc "Requests made against the search endpoint."
  def search_requests, do: requests_of(:search)

  @doc "Requests for subreddit listings, `/new` and `/comments`."
  def listing_requests, do: requests_of(:new) ++ requests_of(:comments)

  @doc "Requests of one kind, as `{method, url}`."
  def requests_of(kind), do: Enum.filter(requests(), fn {_method, url} -> kind(url) == kind end)

  @doc "The decoded query string of a request URL."
  def query(url), do: url |> URI.parse() |> Map.get(:query) |> to_string() |> URI.decode_query()

  @doc "A successful token response."
  def token(expires_in \\ 3_600, token \\ "stub-token") do
    Req.Response.new(
      status: 200,
      body: %{"access_token" => token, "token_type" => "bearer", "expires_in" => expires_in}
    )
  end

  @doc "A successful search response wrapping a decoded listing."
  def listing(body, headers \\ default_rate_limit_headers()) do
    Req.Response.new(status: 200, body: body, headers: headers)
  end

  @doc "An error response with the given status."
  def error(status, headers \\ %{}) do
    Req.Response.new(
      status: status,
      body: %{"message" => "error", "error" => status},
      headers: headers
    )
  end

  @doc "Rate-limit headers as Reddit sends them."
  def rate_limit_headers(remaining, used, reset_in_s) do
    %{
      "x-ratelimit-remaining" => ["#{remaining}"],
      "x-ratelimit-used" => ["#{used}"],
      "x-ratelimit-reset" => ["#{reset_in_s}"]
    }
  end

  defp default_rate_limit_headers, do: rate_limit_headers("58.0", "2.0", "55")

  @doc false
  def run(request) do
    url = URI.to_string(request.url)
    kind = kind(url)

    state = Process.get(@key) || %{script: %{}, requests: []}
    {response, script} = pop(state.script, kind)

    Process.put(@key, %{
      state
      | script: script,
        requests: [{request.method, url} | state.requests]
    })

    response = if is_function(response, 1), do: response.(url), else: response

    {request, response}
  end

  defp pop(script, kind) do
    case Map.get(script, kind) do
      nil ->
        raise "SmmMonitor.RedditStub: no #{kind} response scripted for this request"

      # Last entry repeats, so a steady-state response only has to be given once.
      [last] ->
        {last, script}

      [next | rest] ->
        {next, Map.put(script, kind, rest)}
    end
  end

  defp token_url?(url), do: String.contains?(url, "access_token")

  defp kind(url) do
    path = URI.parse(url).path || ""

    cond do
      token_url?(url) -> :token
      String.ends_with?(path, "/new") -> :new
      String.ends_with?(path, "/comments") -> :comments
      true -> :search
    end
  end
end
