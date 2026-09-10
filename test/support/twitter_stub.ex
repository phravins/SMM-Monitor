defmodule SmmMonitor.TwitterStub do
  @moduledoc """
  A stub HTTP transport for the Twitter fetcher, so tests can exercise the
  real fetch path without a token, a network, or a post from the monthly
  cap.

  Same shape as `SmmMonitor.RedditStub` and `SmmMonitor.YouTubeStub`: Req
  runs its adapter in the calling process, so the script and the recorded
  requests live in that process's dictionary and tests stay async.

      TwitterStub.install(TwitterStub.results(fixture))
      Twitter.fetch(context, state)
      assert TwitterStub.query_params()["query"] =~ "realoffice"

  A list of responses is consumed in order and the last entry repeats.
  """

  @key :twitter_stub

  @doc "Installs a response (or list of responses) for this process."
  def install(responses) do
    Process.put(@key, %{responses: List.wrap(responses), requests: []})
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc "The requests made so far, oldest first, as `{method, url, headers}`."
  def requests do
    case Process.get(@key) do
      nil -> []
      %{requests: requests} -> Enum.reverse(requests)
    end
  end

  @doc "Query parameters of the nth request (0-based)."
  def query_params(index \\ 0) do
    case Enum.at(requests(), index) do
      nil -> %{}
      {_method, url, _headers} -> url |> URI.parse() |> query_of()
    end
  end

  @doc "Request headers of the nth request (0-based), lowercased."
  def request_headers(index \\ 0) do
    case Enum.at(requests(), index) do
      nil ->
        %{}

      {_method, _url, headers} ->
        Map.new(headers, fn {name, value} ->
          {String.downcase(to_string(name)), value |> List.wrap() |> List.first()}
        end)
    end
  end

  @doc """
  A successful recent-search response.

  `headers` overrides the rate-limit headers, which default to a healthy
  window so the happy path doesn't accidentally test backoff.
  """
  def results(body, headers \\ []) do
    Req.Response.new(status: 200, body: body, headers: merge_headers(headers))
  end

  @doc "Rate-limit headers as X sends them: reset is an absolute unix epoch."
  def rate_limit_headers(remaining, reset_in_s \\ 900, limit \\ 450) do
    [
      {"x-rate-limit-limit", to_string(limit)},
      {"x-rate-limit-remaining", to_string(remaining)},
      {"x-rate-limit-reset", to_string(System.system_time(:second) + reset_in_s)}
    ]
  end

  @doc "A 429 for the 15-minute request window."
  def rate_limited(reset_in_s \\ 300) do
    Req.Response.new(
      status: 429,
      headers: rate_limit_headers(0, reset_in_s),
      body: %{"title" => "Too Many Requests", "detail" => "Too Many Requests", "status" => 429}
    )
  end

  @doc """
  A 429 for the monthly post cap.

  A different thing entirely from the window limit — it does not clear in
  fifteen minutes — and X distinguishes them only in the body text.
  """
  def usage_capped do
    Req.Response.new(
      status: 429,
      headers: rate_limit_headers(0, 900),
      body: %{
        "title" => "UsageCapExceeded",
        "detail" => "Usage cap exceeded: Monthly product cap",
        "period" => "Monthly",
        "scope" => "Product",
        "status" => 429,
        "type" => "https://api.twitter.com/2/problems/usage-capped"
      }
    )
  end

  @doc "The 401 X returns for a bad or revoked bearer token."
  def unauthorized do
    Req.Response.new(
      status: 401,
      body: %{"title" => "Unauthorized", "type" => "about:blank", "status" => 401}
    )
  end

  @doc """
  The 403 X returns when the token is valid but the access tier does not
  include recent search — what a free-tier token gets.
  """
  def forbidden do
    Req.Response.new(
      status: 403,
      body: %{
        "title" => "Client Forbidden",
        "detail" =>
          "When authenticating requests to the Twitter API v2 endpoints, " <>
            "you must use keys and tokens from a Twitter developer App that is " <>
            "attached to a Project.",
        "status" => 403
      }
    )
  end

  @doc "An empty result set: no `data` key at all, just a zero count."
  def no_results do
    Req.Response.new(
      status: 200,
      headers: default_rate_limit_headers(),
      body: %{"meta" => %{"result_count" => 0}}
    )
  end

  @doc false
  def run(request) do
    state = Process.get(@key) || %{responses: [], requests: []}
    {response, responses} = pop(state.responses)

    Process.put(@key, %{
      state
      | responses: responses,
        requests: [
          {request.method, URI.to_string(request.url), request.headers} | state.requests
        ]
    })

    {request, response}
  end

  defp default_rate_limit_headers, do: rate_limit_headers(449)

  # Header names are strings, not atoms, so this is a merge by name rather
  # than Keyword.merge/2.
  defp merge_headers(overrides) do
    names = MapSet.new(overrides, fn {name, _value} -> name end)

    Enum.reject(default_rate_limit_headers(), fn {name, _value} ->
      MapSet.member?(names, name)
    end) ++ overrides
  end

  defp query_of(%URI{query: nil}), do: %{}
  defp query_of(%URI{query: query}), do: URI.decode_query(query)

  defp pop([]), do: raise("SmmMonitor.TwitterStub: no response scripted for this request")
  defp pop([last]), do: {last, [last]}
  defp pop([next | rest]), do: {next, rest}
end
