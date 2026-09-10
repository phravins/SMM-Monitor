defmodule SmmMonitor.YouTubeStub do
  @moduledoc """
  A stub HTTP transport for the YouTube fetcher, so tests can exercise the
  real fetch path without touching the network or spending quota.

  Same shape as `SmmMonitor.RedditStub`: Req runs its adapter in the
  calling process, so the script and the recorded requests live in that
  process's dictionary — no shared state between tests.

      YouTubeStub.install(YouTubeStub.results(fixture))
      YouTube.fetch(context, state)
      assert [{:get, url}] = YouTubeStub.requests()

  A list of responses is consumed in order and the last entry repeats.
  """

  @key :youtube_stub

  @doc "Installs a response (or list of responses) for this process."
  def install(responses) do
    Process.put(@key, %{responses: List.wrap(responses), requests: []})
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

  @doc "Query parameters of the nth request (0-based)."
  def query_params(index \\ 0) do
    requests()
    |> Enum.at(index)
    |> case do
      nil -> %{}
      {_method, url} -> url |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()
    end
  end

  @doc "A successful search.list response."
  def results(body), do: Req.Response.new(status: 200, body: body)

  @doc """
  A Google API error response.

  `reason` is the machine-readable code Google puts in `error.errors`,
  e.g. `"quotaExceeded"` or `"keyInvalid"`.
  """
  def error(status, reason) do
    Req.Response.new(
      status: status,
      body: %{
        "error" => %{
          "code" => status,
          "message" => "stubbed #{reason}",
          "errors" => [%{"reason" => reason, "domain" => "youtube.quota"}]
        }
      }
    )
  end

  @doc """
  The 400 Google actually returns for an invalid API key.

  Copied from a real response: the machine-readable `reason` is only
  `"badRequest"`, and the useful part lives in the message and the
  `details` entry.
  """
  def invalid_key_error do
    Req.Response.new(
      status: 400,
      body: %{
        "error" => %{
          "code" => 400,
          "message" => "API key not valid. Please pass a valid API key.",
          "errors" => [
            %{
              "message" => "API key not valid. Please pass a valid API key.",
              "domain" => "global",
              "reason" => "badRequest"
            }
          ],
          "status" => "INVALID_ARGUMENT",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "API_KEY_INVALID",
              "domain" => "googleapis.com",
              "metadata" => %{"service" => "youtube.googleapis.com"}
            }
          ]
        }
      }
    )
  end

  @doc false
  def run(request) do
    state = Process.get(@key) || %{responses: [], requests: []}
    {response, responses} = pop(state.responses)

    Process.put(@key, %{
      state
      | responses: responses,
        requests: [{request.method, URI.to_string(request.url)} | state.requests]
    })

    {request, response}
  end

  defp pop([]), do: raise("SmmMonitor.YouTubeStub: no response scripted for this request")
  defp pop([last]), do: {last, [last]}
  defp pop([next | rest]), do: {next, rest}
end
