defmodule SmmMonitor.NewsStub do
  @moduledoc """
  A stub HTTP transport for the News fetcher.

  Feeds are fetched from tasks (`Task.async_stream`), so the script is
  found through the calling test's process: the test that installed it,
  or any task it started. Tests using it can run async.

      NewsStub.install(%{"opsledger.example" => NewsStub.feed("rss2")})
      News.fetch(context, state)
      assert NewsStub.requested?("opsledger.example")

  A fragment matches any request whose URL contains it, the longest
  match winning; `:any` catches everything else. A value is a response,
  a list of responses (consumed in order, the last one repeating), or a
  function of the `Req.Request`.
  """

  @key :news_stub

  @doc "Installs responses for this test, keyed by URL fragment."
  def install(responses) when is_map(responses) do
    {:ok, script} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    Process.put(@key, script)
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc "Every request so far, oldest first, as `%{url:, headers:}`."
  def requests, do: Agent.get(script!(), &Enum.reverse(&1.requests))

  @doc "The URLs of requests containing `fragment`, oldest first."
  def requests_to(fragment),
    do: for(%{url: url} <- requests(), String.contains?(url, fragment), do: url)

  @doc "Whether any request's URL contained `fragment`."
  def requested?(fragment), do: requests_to(fragment) != []

  @doc "The headers of the `n`th (from 1) request containing `fragment`."
  def headers_of(fragment, n \\ 1) do
    requests()
    |> Enum.filter(&String.contains?(&1.url, fragment))
    |> Enum.at(n - 1)
    |> Map.fetch!(:headers)
  end

  @doc "A 200 with this body."
  def ok(body, headers \\ []),
    do: Req.Response.new(status: 200, body: body, headers: headers)

  @doc "A saved feed from test/fixtures/news, as a 200."
  def feed(name, headers \\ []), do: ok(fixture(name), headers)

  @doc "The text of a saved feed."
  def fixture(name), do: File.read!(Path.join([__DIR__, "..", "fixtures", "news", name <> ".xml"]))

  @doc "A response with no body."
  def status(status, headers \\ []),
    do: Req.Response.new(status: status, body: "", headers: headers)

  @doc false
  def run(request) do
    script = script!()
    url = URI.to_string(request.url)
    headers = Map.new(request.headers, fn {name, values} -> {name, Enum.join(values, ", ")} end)

    response =
      Agent.get_and_update(script, fn state ->
        {response, responses} = pop(state.responses, url)

        {response,
         %{state | responses: responses, requests: [%{url: url, headers: headers} | state.requests]}}
      end)

    response =
      case response do
        fun when is_function(fun, 1) -> fun.(request)
        response -> response
      end

    case response do
      %Req.Response{} -> {request, response}
      exception -> {request, exception}
    end
  end

  defp script! do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, @key)
        nil -> nil
      end
    end)
    |> Kernel.||(raise "SmmMonitor.NewsStub: nothing installed for this test")
  end

  defp pop(responses, url) do
    case matching_key(responses, url) do
      nil ->
        raise "SmmMonitor.NewsStub: no response scripted for #{URI.parse(url).host}"

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

  defp take([]), do: raise("SmmMonitor.NewsStub: response list exhausted")
  defp take([last]), do: {last, [last]}
  defp take([next | rest]), do: {next, rest}
  defp take(response), do: {response, response}
end
