defmodule SmmMonitor.InstagramStub do
  @moduledoc """
  A stub HTTP transport for the Instagram fetcher.

  Instagram differs from the other stubs in one way that matters: a
  single poll can make several requests to *different* paths — tags,
  media, hashtag lookup, hashtag media — so responses are scripted by
  path rather than purely in sequence.

      InstagramStub.install(%{"/tags" => InstagramStub.ok(tags_fixture)})
      Instagram.fetch(context, state)
      assert InstagramStub.requested?("/tags")

  A path key matches any request whose URL contains it. `:any` catches
  everything else. A list of responses under one key is consumed in order,
  with the last entry repeating.
  """

  @key :instagram_stub

  @doc "Installs responses for this process, keyed by URL fragment."
  def install(responses) when is_map(responses) do
    Process.put(@key, %{responses: responses, requests: []})
    :ok
  end

  def install(response), do: install(%{any: response})

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc "The requests made so far, oldest first, as `{method, url}`."
  def requests do
    case Process.get(@key) do
      nil -> []
      %{requests: requests} -> Enum.reverse(requests)
    end
  end

  @doc "Whether any request's URL contained `fragment`."
  def requested?(fragment) do
    Enum.any?(requests(), fn {_method, url} -> String.contains?(url, fragment) end)
  end

  @doc "Query parameters of the first request whose URL contains `fragment`."
  def query_params(fragment) do
    requests()
    |> Enum.find(fn {_method, url} -> String.contains?(url, fragment) end)
    |> case do
      nil -> %{}
      {_method, url} -> url |> URI.parse() |> query_of()
    end
  end

  @doc "How many requests were made in total."
  def request_count, do: length(requests())

  @doc "A successful Graph API response."
  def ok(body, headers \\ []) do
    Req.Response.new(status: 200, body: body, headers: merge_headers(headers))
  end

  @doc """
  Meta's usage header, as a percentage of the hourly allowance.

  `x-business-use-case-usage` is a JSON object keyed by business id.
  """
  def usage_headers(percent, regain_minutes \\ 0) do
    payload =
      Jason.encode!(%{
        "17841400000000000" => [
          %{
            "type" => "instagram",
            "call_count" => percent,
            "total_cputime" => 2,
            "total_time" => 3,
            "estimated_time_to_regain_access" => regain_minutes
          }
        ]
      })

    [{"x-business-use-case-usage", payload}]
  end

  @doc "A Graph API error response."
  def error(status, code, message, extra \\ %{}) do
    Req.Response.new(
      status: status,
      headers: merge_headers([]),
      body: %{
        "error" =>
          Map.merge(
            %{
              "message" => message,
              "type" => "OAuthException",
              "code" => code,
              "fbtrace_id" => "AsdF1234"
            },
            extra
          )
      }
    )
  end

  @doc "The 190/463 Meta returns once a long-lived token passes 60 days."
  def expired_token do
    error(
      400,
      190,
      "Error validating access token: Session has expired on Tuesday, 07-Jul-26 12:00:00 PDT.",
      %{"error_subcode" => 463}
    )
  end

  @doc "The permission error for an edge the token wasn't granted."
  def missing_permission(edge \\ "comments") do
    error(
      403,
      10,
      "(#10) Application does not have permission for this action: #{edge}"
    )
  end

  @doc "Meta's throttling error, with how long it wants us to wait."
  def throttled(minutes \\ 12) do
    error(400, 4, "Application request limit reached", %{
      "error_data" => %{"estimated_time_to_regain_access" => minutes}
    })
  end

  @doc "An empty edge: a valid response with nothing in it."
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
        raise "SmmMonitor.InstagramStub: no response scripted for #{url}"

      key ->
        {response, rest} = take(Map.fetch!(responses, key))
        {response, Map.put(responses, key, rest)}
    end
  end

  # The most specific matching path wins, so "/media" and
  # "/recent_media" can be scripted separately.
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

  defp take(responses) when is_list(responses) do
    case responses do
      [] -> raise "SmmMonitor.InstagramStub: response list exhausted"
      [last] -> {last, [last]}
      [next | rest] -> {next, rest}
    end
  end

  defp take(response), do: {response, response}

  defp merge_headers(overrides) do
    names = MapSet.new(overrides, fn {name, _value} -> name end)

    Enum.reject(usage_headers(5), fn {name, _value} -> MapSet.member?(names, name) end) ++
      overrides
  end

  defp query_of(%URI{query: nil}), do: %{}
  defp query_of(%URI{query: query}), do: URI.decode_query(query)
end
