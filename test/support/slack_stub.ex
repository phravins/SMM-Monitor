defmodule SmmMonitor.SlackStub do
  @moduledoc """
  A stub HTTP transport for the Slack notifier, so tests can assert on
  the payload without posting to a real webhook.

  Same shape as the platform stubs: Req runs its adapter in the calling
  process, so the script and the recorded requests live in that process's
  dictionary and tests stay independent.

      SlackStub.install(SlackStub.ok())
      SlackNotifier.notify(alert)
      assert [{:post, url, body}] = SlackStub.requests()

  The recorded body is already JSON-decoded, since that is what every
  assertion wants.
  """

  @key :slack_stub

  @doc "Installs a response (or list of responses) for this process."
  def install(responses) do
    Process.put(@key, %{responses: List.wrap(responses), requests: []})
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc "Requests made so far, oldest first, as `{method, url, decoded_body}`."
  def requests do
    case Process.get(@key) do
      nil -> []
      %{requests: requests} -> Enum.reverse(requests)
    end
  end

  @doc "Slack's response to a well-formed post."
  def ok, do: Req.Response.new(status: 200, body: "ok")

  @doc """
  Slack's response to a webhook that has been revoked or mistyped.

  It answers 404 with a plain-text reason rather than JSON, which is
  worth stubbing accurately: a notifier that assumes JSON here would
  crash on the one response it most needs to handle.
  """
  def no_service, do: Req.Response.new(status: 404, body: "no_service")

  @doc false
  def run(request) do
    state = Process.get(@key) || %{responses: [], requests: []}
    {response, responses} = pop(state.responses)

    Process.put(@key, %{
      state
      | responses: responses,
        requests: [
          {request.method, URI.to_string(request.url), decode(request.body)} | state.requests
        ]
    })

    {request, response}
  end

  defp decode(nil), do: nil

  defp decode(body) do
    case body |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, decoded} -> decoded
      _invalid -> body
    end
  end

  defp pop([]), do: raise("SmmMonitor.SlackStub: no response scripted for this request")
  defp pop([last]), do: {last, [last]}
  defp pop([next | rest]), do: {next, rest}
end
