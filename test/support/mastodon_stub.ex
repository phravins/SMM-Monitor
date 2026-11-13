defmodule SmmMonitor.MastodonStub do
  @moduledoc """
  A stub HTTP transport for a Mastodon server's REST API, so finding the
  streaming host and catching up after an outage can be tested without
  the network.

  Req runs its adapter in the calling process, so the handler lives in
  that process's dictionary:

      MastodonStub.install(fn request -> {200, []} end)

  A request made by another process, such as a `StreamWorker`, finds no
  handler there; `install_global/1` sets one for every process, until
  `uninstall_global/0`.

  The handler gets the `Req.Request` and returns `{status, body}` or
  `{status, body, headers}`; a map or list body is sent as JSON, and a
  string as it is. Each
  request is also sent to the calling process as
  `{:mastodon_request, request}`.
  """

  @key :mastodon_stub

  @doc "Installs the handler for this process."
  def install(fun) when is_function(fun, 1) do
    Process.put(@key, fun)
    :ok
  end

  @doc "Installs a handler for requests from any process without one of its own."
  def install_global(fun) when is_function(fun, 1) do
    :persistent_term.put(@key, fun)
    :ok
  end

  @doc "Removes the handler set by `install_global/1`."
  def uninstall_global do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc "Req options that route requests to this stub."
  def req_options, do: [adapter: __MODULE__]

  @doc false
  def run(request) do
    fun =
      Process.get(@key) || :persistent_term.get(@key, nil) ||
        raise "MastodonStub.install/1 was not called"

    send(self(), {:mastodon_request, request})

    {status, body, headers} =
      case fun.(request) do
        {status, body} -> {status, body, []}
        {status, body, headers} -> {status, body, headers}
      end

    response =
      if is_binary(body),
        do: Req.Response.new(status: status, headers: headers, body: body),
        else:
          Req.Response.new(
            status: status,
            headers: [{"content-type", "application/json"} | headers],
            body: Jason.encode!(body)
          )

    {request, response}
  end
end
