defmodule SmmMonitor.Fetchers.Mastodon do
  @moduledoc """
  Mastodon, live, through one server's streaming API.

  The fediverse has no central search. Each Mastodon server knows the
  posts written on it and the posts its users' follows bring in from
  other servers, and its streaming API sends every new public one the
  moment the server learns of it. This module listens to one server
  (`MASTODON_INSTANCE`) and matches each post against every client's
  brand terms (`SmmMonitor.Matching`); everything else is thrown away
  unread. A big, well-connected server sees much more of the fediverse
  than a small one.

  ## Turning it on

  Since Mastodon 4.2, public timelines need a signed-in user, so set
  `MASTODON_INSTANCE` (for example `mastodon.social`) and
  `MASTODON_ACCESS_TOKEN`, a token for an account there with the
  `read:statuses` scope. `docs/platforms.md` walks through it.

  `SMM_MASTODON_TIMELINE=local` listens to posts written on that server
  only, instead of everything it knows about (`federated`, the default).

  ## Connection

  The server may run its streaming API on another host; the instance's
  public `/api/v2/instance` names it, and that answer is kept until a
  handshake says it is wrong. `SMM_MASTODON_STREAMING_URL` overrides it.
  The token goes only in the `Authorization` header, over TLS, never in
  a URL.

  A refused token, or a server whose admin has turned live feeds off,
  stops the stream with a message saying so, rather than retrying a
  connection that cannot work.

  ## Catching up after downtime

  The newest post id seen is saved to `mastodon.cursor` next to the
  database every 10 seconds. After a reconnect, the timeline is asked
  over the REST API for what arrived since, 40 posts a page and at most
  10 pages. Mastodon ids carry the time they were made, so a position
  more than an hour old is not caught up from at all. On a busy
  federated timeline this is best effort.

  ## What it never does

  It skips boosts (the original arrives in its own right), anything
  that is not public, and posts with no text. Edits and deletions are not
  followed. Links are built on your own server, never taken from a post.
  """

  use SmmMonitor.Fetchers.Stream, platform: :mastodon, display_name: "Mastodon"

  import Bitwise, only: [>>>: 2]

  require Logger

  alias SmmMonitor.Fetchers.CursorFile
  alias SmmMonitor.WebSocket

  @streaming_path "/api/v1/streaming"

  @id ~r/\A\d{1,25}\z/
  @host ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  # `user` on this server, `user@domain` on another.
  @acct ~r/\A[A-Za-z0-9_](?:[A-Za-z0-9_.-]{0,62}[A-Za-z0-9_])?(?:@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)?\z/

  @save_every_ms 10_000

  @catch_up_per_tick 2
  @catch_up_page 40
  @catch_up_max_pages 10
  @max_catch_up_age_ms 3_600_000
  # A clock that runs ahead on some remote server must not move the
  # position past posts still to come.
  @max_future_ms 300_000

  @refused "Mastodon refused the stream. Check MASTODON_ACCESS_TOKEN: it must be a user's " <>
             "token with the read:statuses scope. The server's admin may also have turned " <>
             "off live feeds."

  defmodule State do
    @moduledoc false
    @derive {Inspect, except: [:token]}
    defstruct token: nil,
              instance: nil,
              streaming_url: nil,
              cursor: nil,
              saved_cursor: nil,
              last_save_mono: nil,
              cursor_file: nil,
              catch_up: nil,
              wait_until_mono: nil,
              unauthorized_logged?: false
  end

  # --- connecting -----------------------------------------------------------------

  @impl true
  def ready?(%{credentials: credentials}),
    do: token(credentials) != nil and instance() != nil

  def ready?(_context), do: false

  @impl true
  def init_state(context) do
    instance = instance()
    file = cursor_file()
    cursor = read_cursor(file, instance)

    %State{
      token: token(Map.get(context, :credentials, [])),
      instance: instance,
      cursor: cursor,
      saved_cursor: cursor,
      cursor_file: file
    }
  end

  defp token(credentials) do
    case Keyword.get(credentials || [], :access_token) do
      token when is_binary(token) ->
        case String.trim(token) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp instance do
    case Keyword.get(settings(), :instance) do
      host when is_binary(host) -> if Regex.match?(@host, host), do: host
      _other -> nil
    end
  end

  # Finds the streaming host once and keeps it; a handshake that says it
  # is wrong clears it (`handle_connect_error/2`).
  @impl true
  def prepare(_context, %State{streaming_url: url} = state) when is_binary(url), do: {:ok, state}
  def prepare(_context, %State{instance: nil} = state), do: {:error, :no_instance, state}

  def prepare(_context, %State{} = state) do
    base = Keyword.get(settings(), :streaming_url) || discover(state.instance)

    case streaming_url(base) do
      {:ok, url} -> {:ok, %{state | streaming_url: url}}
      {:error, reason} -> {:error, {:streaming_url, reason}, state}
    end
  end

  defp discover(instance) do
    request =
      Req.new(
        [
          url: "https://#{instance}/api/v2/instance",
          receive_timeout: 3_000,
          connect_options: [timeout: 3_000],
          retry: false
        ] ++ Keyword.get(settings(), :req_options, [])
      )

    fallback = "wss://" <> instance

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"configuration" => %{"urls" => %{"streaming" => url}}}}}
      when is_binary(url) ->
        case WebSocket.parse_url(url) do
          {:ok, _uri} ->
            url

          {:error, reason} ->
            Logger.warning(
              "mastodon: #{instance} named a streaming host that is not wss:// " <>
                "(#{inspect(reason)}); using #{fallback}"
            )

            fallback
        end

      {:ok, %{status: status}} ->
        Logger.debug("mastodon: instance lookup returned HTTP #{status}; using #{fallback}")
        fallback

      {:error, reason} ->
        Logger.debug("mastodon: instance lookup failed: #{error(reason)}; using #{fallback}")
        fallback
    end
  end

  @doc false
  # The streaming endpoint on `base`, which may or may not already end
  # in the path.
  def streaming_url(base) do
    with {:ok, uri} <- WebSocket.parse_url(base) do
      path = String.trim_trailing(uri.path || "", "/")
      path = if String.ends_with?(path, @streaming_path), do: path, else: path <> @streaming_path
      {:ok, URI.to_string(%{uri | path: path, query: nil, fragment: nil, userinfo: nil})}
    end
  end

  @impl true
  def url(_context, %State{streaming_url: url}) when is_binary(url), do: {:ok, url}
  def url(_context, _state), do: {:error, :no_streaming_url}

  @impl true
  def headers(%State{token: token}) when is_binary(token),
    do: [{"authorization", "Bearer " <> token}]

  def headers(_state), do: []

  @impl true
  def on_open(%State{} = state) do
    frame = Jason.encode!(%{type: "subscribe", stream: stream()})
    {[frame], queue_catch_up(state)}
  end

  defp stream do
    case Keyword.get(settings(), :timeline, :federated) do
      :local -> "public:local"
      _federated -> "public"
    end
  end

  @impl true
  def on_disconnect(%State{} = state), do: save_cursor(%{state | catch_up: nil})

  # Mastodon's streaming server pings every 30 seconds, and a ping counts
  # as traffic, so even a quiet local timeline is never this quiet.
  @impl true
  def idle_timeout_ms, do: 180_000

  @impl true
  def handle_connect_error({:upgrade_refused, code}, state) when code in ["401", "403"],
    do: {:stop, @refused, state}

  # The streaming host moved, or was never where it was looked for: ask
  # the instance again next time.
  def handle_connect_error({:upgrade_refused, "3" <> _rest}, state),
    do: {:reconnect, %{state | streaming_url: nil}}

  def handle_connect_error({:upgrade_refused, "404"}, state),
    do: {:reconnect, %{state | streaming_url: nil}}

  def handle_connect_error(_reason, state), do: {:reconnect, state}

  # --- messages -------------------------------------------------------------------

  @impl true
  def handle_message(%{"event" => "update", "payload" => payload}, %State{} = state)
      when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = status} ->
        state = advance(state, status["id"])
        {:ok, List.wrap(post(status, state.instance)), [], state}

      _not_json ->
        {:ok, [], [], state}
    end
  end

  def handle_message(%{"error" => message, "status" => status}, %State{} = state) do
    Logger.warning("mastodon: the stream returned an error (#{status}): #{inspect(message)}")

    if status in [401, 403, "401", "403"],
      do: {:stop, @refused, state},
      else: {:reconnect, state}
  end

  # Deletions, edits, notifications and anything Mastodon adds later.
  def handle_message(_other, state), do: {:ok, [], [], state}

  # --- statuses to posts ------------------------------------------------------------

  @doc """
  The post for a Mastodon status as `instance` serves it, or nil when it
  is not one to read: a boost, anything not public, one with no text, or
  one whose id or account is malformed.
  """
  @spec post(map(), String.t() | nil) :: map() | nil
  def post(status, instance) when is_map(status) and is_binary(instance) do
    with %{"id" => id, "account" => %{"acct" => acct}} <- status,
         true <- is_binary(id) and Regex.match?(@id, id),
         true <- is_binary(acct) and Regex.match?(@acct, acct),
         nil <- status["reblog"],
         "public" <- status["visibility"],
         text when text != "" <- text(status) do
      %{
        id: "mastodon-#{instance}-#{id}",
        platform: :mastodon,
        author: author(acct, instance),
        text: text,
        # Built from checked parts, never taken from the status, so a link
        # always opens on the user's own server.
        url: "https://#{instance}/@#{acct}/#{id}",
        timestamp: timestamp(status["created_at"])
      }
    else
      _skip -> nil
    end
  end

  def post(_status, _instance), do: nil

  defp author(acct, instance) do
    if String.contains?(acct, "@"), do: "@" <> acct, else: "@#{acct}@#{instance}"
  end

  # The content warning first: a brand named in it is still a mention.
  defp text(status) do
    body = html_to_text(status["content"])

    case status["spoiler_text"] do
      warning when is_binary(warning) ->
        case String.trim(warning) do
          "" -> body
          warning -> String.trim("[CW: #{warning}] " <> body)
        end

      _none ->
        body
    end
  end

  @doc """
  Mastodon's post HTML as plain text: line and paragraph breaks become
  spaces, every other tag goes, and entities are decoded.

      iex> SmmMonitor.Fetchers.Mastodon.html_to_text("<p>Hi &amp; bye</p><p>Next<br>line</p>")
      "Hi & bye Next line"
  """
  @spec html_to_text(term()) :: String.t()
  def html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r{<br\s*/?>|</p>}i, " ")
    |> String.replace(~r/<[^>]*>/, "")
    |> decode_entities()
    |> String.split()
    |> Enum.join(" ")
  end

  def html_to_text(_other), do: ""

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  defp decode_entities(text) do
    Regex.replace(~r/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});/, text, fn all, name ->
      case name do
        "#x" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#X" <> hex -> codepoint(Integer.parse(hex, 16), all)
        "#" <> decimal -> codepoint(Integer.parse(decimal), all)
        name -> Map.get(@entities, name, all)
      end
    end)
  end

  # Only real characters: not NUL, not a surrogate, not past Unicode.
  defp codepoint({code, ""}, _all)
       when code in 1..0xD7FF or code in 0xE000..0x10FFFF,
       do: <<code::utf8>>

  defp codepoint(_parsed, _all), do: ""

  defp timestamp(iso) when is_binary(iso) do
    now = DateTime.utc_now()

    case DateTime.from_iso8601(iso) do
      # A remote server's clock can be ahead; a post from the future would
      # sit at the top of the list for ever.
      {:ok, datetime, _offset} -> if DateTime.after?(datetime, now), do: now, else: datetime
      {:error, _reason} -> now
    end
  end

  defp timestamp(_other), do: DateTime.utc_now()

  # --- position and catch-up --------------------------------------------------------

  # Every status that arrives moves the position, matched or not, so a
  # catch-up never re-reads what was already seen.
  defp advance(state, id) when is_binary(id) do
    if Regex.match?(@id, id) and not future?(id) and newer?(id, state.cursor),
      do: %{state | cursor: id},
      else: state
  end

  defp advance(state, _id), do: state

  # Ids grow with time; compare them as numbers, not strings.
  defp newer?(_id, nil), do: true
  defp newer?(a, b), do: String.to_integer(a) > String.to_integer(b)

  @doc false
  # The time a Mastodon id was made, in Unix ms: the top 48 bits.
  def id_ms(id), do: String.to_integer(id) >>> 16

  defp future?(id), do: id_ms(id) > System.os_time(:millisecond) + @max_future_ms

  # The position is taken now: live posts arriving before the fetch move
  # the cursor on, and fetching from there would skip the gap.
  defp queue_catch_up(%State{cursor: nil} = state), do: %{state | catch_up: nil}

  defp queue_catch_up(%State{cursor: cursor} = state) do
    if System.os_time(:millisecond) - id_ms(cursor) > @max_catch_up_age_ms,
      do: %{state | catch_up: nil},
      else: %{state | catch_up: %{after: cursor, pages: 0}}
  end

  @impl true
  def tick(%State{} = state) do
    {posts, state} = catch_up(state)
    now = now()

    state =
      if state.last_save_mono == nil or now - state.last_save_mono >= @save_every_ms,
        do: save_cursor(%{state | last_save_mono: now}),
        else: state

    {posts, state}
  end

  defp catch_up(%State{catch_up: nil} = state), do: {[], state}

  defp catch_up(state) do
    Enum.reduce(1..@catch_up_per_tick, {[], state}, fn _turn, {posts, state} ->
      if state.catch_up == nil or waiting?(state) do
        {posts, state}
      else
        {more, state} = fetch_page(state.catch_up, state)
        {posts ++ more, state}
      end
    end)
  end

  defp waiting?(%State{wait_until_mono: nil}), do: false
  defp waiting?(state), do: now() < state.wait_until_mono

  defp fetch_page(item, state) do
    params = [min_id: item.after, limit: @catch_up_page]
    params = if stream() == "public:local", do: [{:local, true} | params], else: params

    request =
      Req.new(
        [
          url: "https://#{state.instance}/api/v1/timelines/public",
          params: params,
          headers: [{"authorization", "Bearer " <> state.token}],
          receive_timeout: 5_000,
          connect_options: [timeout: 5_000],
          retry: false
        ] ++ Keyword.get(settings(), :req_options, [])
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: statuses} = response} when is_list(statuses) ->
        caught_up(item, statuses, rate_limit(state, response))

      {:ok, %{status: 429} = response} ->
        ms = reset_ms(response) || 30_000
        {[], %{state | wait_until_mono: now() + ms}}

      {:ok, %{status: 401}} ->
        if not state.unauthorized_logged?,
          do: Logger.warning("mastodon: catch-up refused (HTTP 401); check MASTODON_ACCESS_TOKEN")

        {[], %{state | catch_up: nil, unauthorized_logged?: true}}

      {:ok, %{status: status}} ->
        Logger.debug("mastodon: catch-up returned HTTP #{status}")
        {[], %{state | catch_up: nil}}

      {:error, reason} ->
        Logger.debug("mastodon: catch-up failed: #{error(reason)}")
        {[], %{state | catch_up: nil}}
    end
  end

  defp caught_up(item, statuses, state) do
    statuses =
      statuses
      |> Enum.filter(&(is_map(&1) and is_binary(&1["id"]) and Regex.match?(@id, &1["id"])))
      |> Enum.sort_by(&String.to_integer(&1["id"]))

    state = Enum.reduce(statuses, state, &advance(&2, &1["id"]))
    posts = statuses |> Enum.map(&post(&1, state.instance)) |> Enum.reject(&is_nil/1)

    # A full page may mean more after it.
    catch_up =
      case List.last(statuses) do
        %{"id" => newest} when length(statuses) == @catch_up_page ->
          if item.pages + 1 < @catch_up_max_pages,
            do: %{after: newest, pages: item.pages + 1}

        _fewer ->
          nil
      end

    {posts, %{state | catch_up: catch_up}}
  end

  defp rate_limit(state, response) do
    with "0" <- header(response, "x-ratelimit-remaining"),
         ms when is_integer(ms) <- reset_ms(response) do
      %{state | wait_until_mono: now() + ms}
    else
      _plenty -> state
    end
  end

  # Mastodon gives the reset as a time, not a number of seconds.
  defp reset_ms(response) do
    with value when is_binary(value) <- header(response, "x-ratelimit-reset"),
         {:ok, reset, _offset} <- DateTime.from_iso8601(value) do
      reset |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(1_000) |> min(300_000)
    else
      _missing -> nil
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Only the error itself: never the request, which carries the token.
  defp error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error(reason), do: inspect(reason)

  # --- the cursor file ------------------------------------------------------------

  defp cursor_file do
    case Keyword.fetch(settings(), :cursor_file) do
      {:ok, file} -> file
      :error -> CursorFile.default_path("mastodon.cursor")
    end
  end

  # A position from another server is not this one's.
  defp read_cursor(file, instance) do
    with contents when is_binary(contents) <- CursorFile.read(file),
         {:ok, %{"instance" => ^instance, "last" => last}} <- Jason.decode(contents),
         true <- is_binary(last) and Regex.match?(@id, last) do
      last
    else
      _missing_or_bad -> nil
    end
  end

  defp save_cursor(%State{cursor_file: nil} = state), do: state
  defp save_cursor(%State{cursor: nil} = state), do: state
  defp save_cursor(%State{cursor: same, saved_cursor: same} = state), do: state

  defp save_cursor(state) do
    contents = Jason.encode!(%{version: 1, instance: state.instance, last: state.cursor})

    case CursorFile.write(state.cursor_file, contents) do
      :ok ->
        %{state | saved_cursor: state.cursor}

      {:error, reason} ->
        Logger.warning("mastodon: could not save the stream position: #{inspect(reason)}")
        state
    end
  end

  defp settings, do: Application.get_env(:smm_monitor, __MODULE__, [])
end
