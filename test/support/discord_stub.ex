defmodule SmmMonitor.DiscordStub do
  @moduledoc """
  A stub HTTP transport for Discord's REST API, so the catch-up after an
  outage can be tested without the network.

  Req runs its adapter in the calling process, so the handler lives in
  that process's dictionary:

      DiscordStub.install(fn request -> {200, []} end)

  The handler gets the `Req.Request` and returns `{status, body}` or
  `{status, body, headers}`; a map or list body is sent as JSON. Each
  request is also sent to the calling process as
  `{:discord_request, request}`.
  """

  @key :discord_stub

  @doc "Installs the handler for this process."
  def install(fun) when is_function(fun, 1) do
    Process.put(@key, fun)
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc false
  def run(request) do
    fun = Process.get(@key) || raise "DiscordStub.install/1 was not called"
    send(self(), {:discord_request, request})

    {status, body, headers} =
      case fun.(request) do
        {status, body} -> {status, body, []}
        {status, body, headers} -> {status, body, headers}
      end

    response =
      Req.Response.new(
        status: status,
        headers: [{"content-type", "application/json"} | headers],
        body: if(is_binary(body), do: body, else: Jason.encode!(body))
      )

    {request, response}
  end
end
