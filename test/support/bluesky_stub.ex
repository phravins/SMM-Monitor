defmodule SmmMonitor.BlueskyStub do
  @moduledoc """
  A stub HTTP transport for Bluesky's profile lookup, so handle
  resolution can be tested without the network.

  Req runs its adapter in the calling process, so the handler lives in
  that process's dictionary:

      BlueskyStub.install(fn request -> {200, %{"profiles" => []}} end)

  The handler gets the `Req.Request` and returns `{status, body}`; a map
  body is sent as JSON.
  """

  @key :bluesky_stub

  @doc "Installs the handler for this process."
  def install(fun) when is_function(fun, 1) do
    Process.put(@key, fun)
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc false
  def run(request) do
    fun = Process.get(@key) || raise "BlueskyStub.install/1 was not called"
    {status, body} = fun.(request)

    response =
      Req.Response.new(
        status: status,
        headers: [{"content-type", "application/json"}],
        body: if(is_binary(body), do: body, else: Jason.encode!(body))
      )

    {request, response}
  end
end
