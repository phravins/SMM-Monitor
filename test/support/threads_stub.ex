defmodule SmmMonitor.ThreadsStub do
  @moduledoc """
  A stub HTTP transport for the Threads fetcher.

  One poll can call several endpoints — `/me`, `/keyword_search`,
  `/mentions`, `/threads`, `/replies`, `/refresh_access_token` — so
  responses are scripted by URL fragment, as in `InstagramStub`:

      ThreadsStub.install(%{"/keyword_search" => ThreadsStub.ok(fixture)})
      Threads.fetch(context, state)
      assert ThreadsStub.requested?("/keyword_search")

  A fragment matches any request whose URL contains it, the longest match
  winning. `:any` catches everything else. A list under one key is
  consumed in order, with the last entry repeating. The script lives in
  the process dictionary, so tests using it can run async.
  """

  @key :threads_stub

  @doc "Installs responses for this process, keyed by URL fragment."
  def install(responses) when is_map(responses) do
    Process.put(@key, %{responses: responses, requests: []})
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

  @doc "The URLs of requests containing `fragment`, oldest first."
  def requests_to(fragment) do
    for {_method, url} <- requests(), String.contains?(url, fragment), do: url
  end

  @doc "Whether any request's URL contained `fragment`."
  def requested?(fragment), do: requests_to(fragment) != []

  @doc "Query parameters of the first request whose URL contains `fragment`."
  def query_params(fragment) do
    case requests_to(fragment) do
      [] -> %{}
      [url | _rest] -> query_of(url)
    end
  end

  @doc "Query parameters of every request whose URL contains `fragment`."
  def all_query_params(fragment), do: Enum.map(requests_to(fragment), &query_of/1)

  @doc "How many requests were made in total."
  def request_count, do: length(requests())

  @doc "A successful response."
  def ok(body, headers \\ []), do: Req.Response.new(status: 200, body: body, headers: headers)

  @doc "A list of posts, as `/keyword_search`, `/mentions` and `/replies` return them."
  def posts(posts), do: ok(%{"data" => posts})

  @doc "One post with sensible defaults."
  def post(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "18000000000000001",
        "text" => "loving acme today",
        "media_type" => "TEXT_POST",
        "permalink" => "https://www.threads.com/@maya.makes/post/C1aB2cD3eF4",
        "timestamp" => "2026-11-12T10:00:00+0000",
        "username" => "maya.makes"
      },
      overrides
    )
  end

  @doc "`/me` for the connected account."
  def me(id \\ "17841400000000001", username \\ "acme"),
    do: ok(%{"id" => id, "username" => username})

  @doc "A successful token renewal."
  def renewed(token \\ "THAArenewedtoken0000000000", expires_in \\ 5_184_000),
    do: ok(%{"access_token" => token, "token_type" => "bearer", "expires_in" => expires_in})

  @doc "A Graph API error response."
  def error(status, code, message, extra \\ %{}) do
    Req.Response.new(
      status: status,
      body: %{
        "error" =>
          Map.merge(
            %{"message" => message, "type" => "OAuthException", "code" => code},
            extra
          )
      }
    )
  end

  @doc "What Meta returns for an expired or revoked token."
  def expired_token do
    error(401, 190, "Error validating access token: Session has expired.", %{
      "error_subcode" => 463
    })
  end

  @doc "The error for a permission the token wasn't granted."
  def missing_permission(scope \\ "threads_keyword_search") do
    error(403, 10, "(#10) Application does not have permission for this action: #{scope}")
  end

  @doc "Meta's throttling error, with how long it wants us to wait."
  def throttled(code \\ 4, minutes \\ 12) do
    error(400, code, "Application request limit reached", %{
      "error_data" => %{"estimated_time_to_regain_access" => minutes}
    })
  end

  @doc "An empty list: a valid answer with nothing in it."
  def empty, do: ok(%{"data" => []})

  @doc false
  def run(request) do
    state = Process.get(@key) || %{responses: %{}, requests: []}
    url = URI.to_string(request.url)
    {response, responses} = pop(state.responses, url)

    Process.put(@key, %{
      state
      | responses: responses,
        requests: [{request.method, url} | state.requests]
    })

    {request, response}
  end

  defp pop(responses, url) do
    case matching_key(responses, url) do
      nil ->
        # Never put the URL in the message: it carries the token.
        raise "SmmMonitor.ThreadsStub: no response scripted for #{URI.parse(url).path}"

      key ->
        {response, rest} = take(Map.fetch!(responses, key))
        {response, Map.put(responses, key, rest)}
    end
  end

  defp matching_key(responses, url) do
    responses
    |> Map.keys()
    |> Enum.filter(&(is_binary(&1) and String.contains?(url, &1)))
    |> Enum.max_by(&String.length/1, fn -> nil end)
    |> case do
      nil -> if Map.has_key?(responses, :any), do: :any, else: nil
      key -> key
    end
  end

  defp take([]), do: raise("SmmMonitor.ThreadsStub: response list exhausted")
  defp take([last]), do: {last, [last]}
  defp take([next | rest]), do: {next, rest}
  defp take(response), do: {response, response}

  defp query_of(url) do
    case URI.parse(url) do
      %URI{query: nil} -> %{}
      %URI{query: query} -> URI.decode_query(query)
    end
  end
end
