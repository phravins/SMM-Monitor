defmodule SmmMonitor.Fetchers.News.HTTP do
  @moduledoc """
  Fetches one feed: politely, and without trusting the server.

    * **Conditional requests.** The `ETag` and `Last-Modified` a feed sent
      last time go back as `If-None-Match` and `If-Modified-Since`, so an
      unchanged feed costs a `304` and no body.
    * **Redirects by hand.** At most 3 hops, each to `https` (plain
      `http` only to this machine, for tests). A permanent redirect is
      reported back so the operator can be told to update the address.
    * **A size cap.** The body is read in chunks and abandoned past
      `:max_body_bytes` (5 MB by default). Compressed responses are not
      asked for and not decompressed: a few kilobytes of gzip can unpack
      to gigabytes.
    * **No retries here.** A failed feed is retried on a later poll, with
      a growing gap; that is `SmmMonitor.Fetchers.News`'s job.
  """

  @max_redirects 3
  @default_max_body 5 * 1024 * 1024
  @default_rate_limit_ms :timer.minutes(30)

  @accept "application/rss+xml, application/atom+xml, application/rdf+xml;q=0.9, " <>
            "application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5"

  @type validators :: %{optional(:etag) => String.t(), optional(:last_modified) => String.t()}

  @type meta :: %{
          etag: String.t() | nil,
          last_modified: String.t() | nil,
          moved_to: String.t() | nil
        }

  @doc """
  GETs `url`. Returns the body, `:not_modified`, or an error that never
  carries the URL or a header (a private feed's address can hold a key).
  """
  @spec get(String.t(), validators(), keyword()) ::
          {:ok, binary(), meta()}
          | {:not_modified, meta()}
          | {:error, term()}
  def get(url, validators, settings) do
    request(url, validators, settings, 0, nil)
  end

  @doc """
  Whether `url` may be fetched: `https`, or `http` to this machine.
  No user name or password in it.

      iex> SmmMonitor.Fetchers.News.HTTP.fetchable?("https://news.example/feed")
      true
      iex> SmmMonitor.Fetchers.News.HTTP.fetchable?("http://news.example/feed")
      false
      iex> SmmMonitor.Fetchers.News.HTTP.fetchable?("http://127.0.0.1:4000/feed")
      true
      iex> SmmMonitor.Fetchers.News.HTTP.fetchable?("https://user:pw@news.example/feed")
      false
  """
  @spec fetchable?(term()) :: boolean()
  def fetchable?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) and host != "" ->
        true

      {:ok, %URI{scheme: "http", host: host, userinfo: nil}} ->
        loopback?(host)

      _other ->
        false
    end
  end

  def fetchable?(_other), do: false

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp request(url, validators, settings, hops, moved_to) do
    max_body = Keyword.get(settings, :max_body_bytes, @default_max_body)

    [
      method: :get,
      url: url,
      headers: headers(validators),
      # Each hop is checked before it is followed; see below.
      redirect: false,
      # Retrying is the fetcher's job, on a later poll.
      retry: false,
      # No gzip asked for, and none unpacked if it is sent anyway.
      compressed: false,
      raw: true,
      receive_timeout: 10_000,
      connect_options: [timeout: 10_000],
      into: capped(max_body)
    ]
    |> Kernel.++(Keyword.get(settings, :req_options, []))
    |> Req.new()
    |> Req.request()
    |> handle(url, validators, settings, hops, moved_to, max_body)
  end

  defp headers(validators) do
    [{"user-agent", user_agent()}, {"accept", @accept}]
    |> add_header("if-none-match", validators[:etag])
    |> add_header("if-modified-since", validators[:last_modified])
  end

  # Names the software, never the operator or the brands being watched.
  defp user_agent do
    "smm_monitor/#{Application.spec(:smm_monitor, :vsn) || "dev"} (feed reader)"
  end

  defp add_header(headers, _name, nil), do: headers
  defp add_header(headers, name, value), do: headers ++ [{name, value}]

  # Reads the body chunk by chunk and stops once it is too big.
  defp capped(max_body) do
    fn {:data, data}, {request, response} ->
      if byte_size(response.body) + byte_size(data) > max_body do
        {:halt, {request, Req.Response.put_private(%{response | body: ""}, :too_large, true)}}
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
    end
  end

  defp handle({:ok, %Req.Response{status: 200} = response}, _url, _v, _s, _hops, moved_to, max) do
    cond do
      Req.Response.get_private(response, :too_large) -> {:error, :too_large}
      not is_binary(response.body) -> {:error, :bad_response}
      byte_size(response.body) > max -> {:error, :too_large}
      true -> {:ok, response.body, meta(response, moved_to)}
    end
  end

  defp handle({:ok, %Req.Response{status: 304} = response}, _url, _v, _s, _hops, moved_to, _max),
    do: {:not_modified, meta(response, moved_to)}

  defp handle(
         {:ok, %Req.Response{status: status} = response},
         url,
         validators,
         settings,
         hops,
         moved_to,
         _max
       )
       when status in [301, 302, 303, 307, 308] do
    with {:hops, true} <- {:hops, hops < @max_redirects},
         [location | _rest] <- Req.Response.get_header(response, "location"),
         {:ok, next} <- resolve(url, location),
         true <- fetchable?(next) do
      # Only a chain of permanent moves is worth changing the address for.
      permanent? = status in [301, 308] and (hops == 0 or moved_to != nil)
      moved_to = if permanent?, do: next, else: nil
      request(next, validators, settings, hops + 1, moved_to)
    else
      {:hops, false} -> {:error, :too_many_redirects}
      _bad -> {:error, {:bad_redirect, status}}
    end
  end

  defp handle({:ok, %Req.Response{status: status} = response}, _url, _v, _s, _h, _m, _max)
       when status in [429, 503] do
    {:error, {:rate_limited, retry_after_ms(response)}}
  end

  defp handle({:ok, %Req.Response{status: status}}, _url, _v, _s, _h, _m, _max),
    do: {:error, {:http_error, status}}

  # Only the reason: an exception's request carries the URL.
  defp handle({:error, %{reason: reason}}, _url, _v, _s, _h, _m, _max)
       when is_atom(reason) or is_tuple(reason),
       do: {:error, {:transport, transport_reason(reason)}}

  defp handle({:error, _exception}, _url, _v, _s, _h, _m, _max),
    do: {:error, {:transport, :unknown}}

  defp transport_reason(reason) when is_atom(reason), do: reason
  defp transport_reason({:tls_alert, {alert, _message}}), do: {:tls_alert, alert}
  defp transport_reason(_other), do: :unknown

  defp resolve(url, location) do
    {:ok, url |> URI.merge(String.trim(location)) |> URI.to_string()}
  rescue
    ArgumentError -> :error
  end

  defp meta(response, moved_to) do
    %{
      etag: validator(response, "etag"),
      last_modified: validator(response, "last-modified"),
      moved_to: moved_to
    }
  end

  # Sent back verbatim next time, so only printable ASCII of a sane length.
  defp validator(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> if Regex.match?(~r/\A[\x20-\x7E]{1,256}\z/, value), do: value
      [] -> nil
    end
  end

  defp retry_after_ms(response) do
    with [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds > 0 <- Integer.parse(String.trim(value)) do
      # A day at most: a typo in a header should not park a feed for a year.
      min(seconds, 86_400) * 1_000
    else
      _none -> @default_rate_limit_ms
    end
  end
end
