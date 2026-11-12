defmodule SmmMonitor.Fetchers.Discord do
  @moduledoc """
  Discord, live, as a bot in the servers it has been invited to.

  Discord has no public search: a bot sees only the servers it is a
  member of, and only the channels it is allowed to view. It receives
  every new message there through the Gateway, Discord's WebSocket, about
  a second after it is sent. Each message is matched against every
  client's brand terms (`SmmMonitor.Matching`), as on every other
  platform; everything else is thrown away unread.

  ## Turning it on

  Create a bot in the Discord Developer Portal, switch on its **Message
  Content Intent**, invite it to the servers to watch and set
  `DISCORD_BOT_TOKEN`. `docs/platforms.md` walks through it.

  `SMM_DISCORD_GUILDS` and `SMM_DISCORD_CHANNELS` narrow where it listens:
  when either is set, a message is read only if its server is in the
  first list or its channel (or, for a thread, the thread's parent
  channel) is in the second.

  ## Connection

  Discord speaks first (Hello, with the heartbeat interval). The bot
  answers with Identify, or with Resume when it has a session from an
  earlier connection, and then beats at that interval. A beat that was
  never acknowledged means the connection is dead even if the socket is
  not, so the next beat reconnects instead.

  Closing with code 4000 rather than 1000 keeps the session resumable,
  and Discord then replays whatever was sent while the bot was away.

  ## Catching up after downtime

  The id of the last message seen in each channel is saved to
  `discord.cursor` next to the database every 10 seconds. When a session
  cannot be resumed (after a restart, or a long outage), the channels in
  that file are asked over the REST API for what was posted since, a
  page of 100 at a time and at most 10 pages per channel.

  ## What it never does

  It reads no direct messages, no messages from bots or webhooks, and
  nothing in a server it has not been invited to. Edits and deletions are
  not followed.
  """

  use SmmMonitor.Fetchers.Stream, platform: :discord, display_name: "Discord"

  require Logger

  alias SmmMonitor.Fetchers.CursorFile
  alias SmmMonitor.WebSocket

  @gateway_url "wss://gateway.discord.gg/"
  @gateway_query "v=10&encoding=json"
  @api_url "https://discord.com/api/v10"

  # GUILDS (1) + GUILD_MESSAGES (512) + MESSAGE_CONTENT (32768).
  @intents 33_281

  # Default (0) and reply (19). Joins, pins, boosts and the like carry no
  # text worth matching.
  @message_types [0, 19]

  @snowflake ~r/\A\d{1,20}\z/

  @save_every_ms 10_000
  @max_saved_channels 500
  @max_cached 10_000

  @catch_up_per_tick 2
  @catch_up_page 100
  @catch_up_max_pages 10

  defmodule State do
    @moduledoc false
    defstruct token: nil,
              session_id: nil,
              resume_url: nil,
              seq: nil,
              heartbeat_interval: nil,
              next_beat_ms: nil,
              acked?: true,
              guilds: %{},
              channels: %{},
              last_seen: %{},
              saved: %{},
              last_save_mono: nil,
              cursor_file: nil,
              catch_up: [],
              wait_until_mono: nil,
              unauthorized_logged?: false
  end

  # --- connecting -----------------------------------------------------------------

  @impl true
  def ready?(%{credentials: credentials}), do: token(credentials) != nil
  def ready?(_context), do: false

  @impl true
  def init_state(context) do
    file = cursor_file()
    last_seen = read_last_seen(file)

    %State{
      token: token(Map.get(context, :credentials, [])),
      cursor_file: file,
      last_seen: last_seen,
      saved: last_seen
    }
  end

  defp token(credentials) do
    case Keyword.get(credentials || [], :bot_token) do
      token when is_binary(token) ->
        case String.trim(token) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  @impl true
  def url(_context, %State{} = state) do
    base =
      cond do
        override = Keyword.get(settings(), :gateway_url) -> override
        state.session_id && state.resume_url -> state.resume_url
        true -> @gateway_url
      end

    case WebSocket.parse_url(base) do
      {:ok, uri} ->
        path = if uri.path in [nil, ""], do: "/", else: uri.path
        {:ok, URI.to_string(%{uri | path: path, query: @gateway_query})}

      {:error, reason} ->
        {:error, {:gateway_url, reason}}
    end
  end

  # The token goes to whatever URL this returns, so only Discord's own
  # gateway hosts are accepted from a READY message.
  @doc false
  def resume_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host, userinfo: nil} when is_binary(host) ->
        if String.ends_with?(host, ".discord.gg") and Regex.match?(~r/\A[a-z0-9.-]+\z/, host),
          do: "wss://" <> host

      _other ->
        nil
    end
  end

  def resume_url(_url), do: nil

  # Discord speaks first; anything left over from the last connection's
  # heartbeat must not be used before it does.
  @impl true
  def on_open(%State{} = state), do: {[], reset_heartbeat(state)}

  @impl true
  def on_disconnect(%State{} = state), do: state |> reset_heartbeat() |> save_cursor()

  defp reset_heartbeat(state),
    do: %{state | heartbeat_interval: nil, next_beat_ms: nil, acked?: true}

  @impl true
  def idle_timeout_ms, do: 150_000

  @impl true
  def max_message_bytes, do: 8 * 1_048_576

  # 4000 keeps the session alive for a resume; 1000 would end it.
  @impl true
  def close_code(%State{session_id: nil}), do: 1000
  def close_code(%State{}), do: 4000

  @impl true
  def handle_close(4004, state),
    do: {:stop, "Discord rejected the bot token. Check DISCORD_BOT_TOKEN.", state}

  def handle_close(4014, state) do
    {:stop,
     "Discord refused the Message Content intent. Turn on Message Content Intent " <>
       "in the Discord Developer Portal, under Bot.", state}
  end

  def handle_close(code, state) when code in [4010, 4011] do
    {:stop, "The bot is in too many servers for one connection (Discord requires sharding).", state}
  end

  def handle_close(code, state) when code in [4012, 4013] do
    {:stop, "Discord refused the connection settings (close code #{code}). This is a bug.", state}
  end

  def handle_close(code, state) when code in [4007, 4009],
    do: {:reconnect, clear_session(state)}

  def handle_close(_code, state), do: {:reconnect, state}

  defp clear_session(state), do: %{state | session_id: nil, resume_url: nil, seq: nil}

  # --- heartbeat ------------------------------------------------------------------

  @impl true
  def heartbeat_ms(%State{next_beat_ms: ms}), do: ms

  # The previous beat was never acknowledged: the connection is dead even
  # if the socket is not.
  @impl true
  def heartbeat(%State{acked?: false} = state), do: {:reconnect, state}

  def heartbeat(%State{} = state) do
    {[beat(state)], %{state | acked?: false, next_beat_ms: state.heartbeat_interval}}
  end

  defp beat(state), do: Jason.encode!(%{op: 1, d: state.seq})

  # --- messages -------------------------------------------------------------------

  @impl true
  def handle_message(%{"op" => op} = message, %State{} = state) do
    state = track_seq(state, message)
    gateway(op, message, state)
  end

  def handle_message(_other, state), do: {:ok, [], [], state}

  defp track_seq(state, %{"op" => 0, "s" => seq}) when is_integer(seq), do: %{state | seq: seq}
  defp track_seq(state, _message), do: state

  # Hello: start beating, then identify or resume.
  defp gateway(10, %{"d" => %{"heartbeat_interval" => interval}}, state)
       when is_integer(interval) and interval > 0 do
    # The first beat is at a random point in the interval, as Discord asks,
    # so that many clients reconnecting at once do not beat together.
    first = max(1, round(interval * :rand.uniform()))
    state = %{state | heartbeat_interval: interval, next_beat_ms: first, acked?: true}
    {:ok, [], [hello_reply(state)], state}
  end

  defp gateway(11, _message, state), do: {:ok, [], [], %{state | acked?: true}}
  defp gateway(1, _message, state), do: {:ok, [], [beat(state)], state}
  defp gateway(7, _message, state), do: {:reconnect, state}
  defp gateway(9, %{"d" => true}, state), do: {:reconnect, state}
  defp gateway(9, _message, state), do: {:reconnect, clear_session(state)}

  defp gateway(0, %{"t" => event, "d" => data}, state) when is_map(data),
    do: dispatch(event, data, state)

  defp gateway(_op, _message, state), do: {:ok, [], [], state}

  @doc false
  def hello_reply(%State{session_id: session_id, seq: seq} = state)
      when is_binary(session_id) and is_integer(seq) do
    Jason.encode!(%{op: 6, d: %{token: state.token, session_id: session_id, seq: seq}})
  end

  def hello_reply(%State{} = state) do
    Jason.encode!(%{
      op: 2,
      d: %{
        token: state.token,
        intents: @intents,
        properties: %{os: os(), browser: "smm_monitor", device: "smm_monitor"}
      }
    })
  end

  defp os, do: :os.type() |> elem(1) |> Atom.to_string()

  defp dispatch("READY", data, state) do
    guilds = data["guilds"]

    if guilds == [] do
      Logger.warning(
        "discord: the bot is not in any server yet. Invite it with the link in " <>
          "docs/platforms.md#discord."
      )
    end

    state = %{
      state
      | session_id: string_or_nil(data["session_id"]),
        resume_url: resume_url(data["resume_gateway_url"])
    }

    {:ok, [], [], queue_catch_up(state)}
  end

  # Discord replays what was missed after a resume, so there is nothing to
  # fetch.
  defp dispatch("RESUMED", _data, state), do: {:ok, [], [], state}

  defp dispatch("GUILD_CREATE", %{"id" => guild} = data, state) do
    state = put_guild(state, guild, data["name"])

    state =
      Enum.reduce(List.wrap(data["channels"]) ++ List.wrap(data["threads"]), state, fn
        channel, state -> put_channel(state, Map.put_new(channel, "guild_id", guild))
      end)

    {:ok, [], [], state}
  end

  defp dispatch("GUILD_UPDATE", %{"id" => guild} = data, state),
    do: {:ok, [], [], put_guild(state, guild, data["name"])}

  defp dispatch("GUILD_DELETE", %{"id" => guild}, state),
    do: {:ok, [], [], %{state | guilds: Map.delete(state.guilds, guild)}}

  defp dispatch(event, data, state)
       when event in ~w(CHANNEL_CREATE CHANNEL_UPDATE THREAD_CREATE THREAD_UPDATE),
       do: {:ok, [], [], put_channel(state, data)}

  defp dispatch(event, %{"id" => id}, state) when event in ~w(CHANNEL_DELETE THREAD_DELETE),
    do: {:ok, [], [], %{state | channels: Map.delete(state.channels, id)}}

  defp dispatch("THREAD_LIST_SYNC", %{"guild_id" => guild} = data, state) do
    state =
      Enum.reduce(List.wrap(data["threads"]), state, fn thread, state ->
        put_channel(state, Map.put_new(thread, "guild_id", guild))
      end)

    {:ok, [], [], state}
  end

  defp dispatch("MESSAGE_CREATE", message, state) do
    state = remember_position(state, message)
    {:ok, List.wrap(post(message, state)), [], state}
  end

  defp dispatch(_event, _data, state), do: {:ok, [], [], state}

  # --- messages to posts ------------------------------------------------------------

  @doc """
  The post for a Discord message, or nil when it is not one to read: a
  direct message, a bot's or webhook's message, a system message, an
  empty one, one outside the allow-list, or one whose ids are malformed.
  """
  @spec post(map(), %State{}) :: map() | nil
  def post(message, %State{} = state) do
    with %{"id" => id, "channel_id" => channel, "guild_id" => guild, "content" => content} <-
           message,
         true <- Enum.all?([id, channel, guild], &snowflake?/1),
         true <- is_binary(content) and String.trim(content) != "",
         true <- message["type"] in @message_types,
         true <- is_nil(message["webhook_id"]),
         %{} = author <- message["author"],
         true <- author["bot"] != true,
         true <- allowed?(state, guild, channel) do
      %{
        id: id,
        platform: :discord,
        author: author_label(author, state.channels[channel]),
        text: readable(content, message, state),
        # Built from checked ids, never taken from the message, so a link
        # always goes to discord.com.
        url: "https://discord.com/channels/#{guild}/#{channel}/#{id}",
        timestamp: timestamp(message["timestamp"])
      }
    else
      _skip -> nil
    end
  end

  defp snowflake?(id), do: is_binary(id) and Regex.match?(@snowflake, id)

  @doc false
  def allowed?(%State{} = state, guild, channel) do
    guilds = Keyword.get(settings(), :guilds, [])
    channels = Keyword.get(settings(), :channels, [])

    cond do
      guilds == [] and channels == [] -> true
      guild in guilds -> true
      channel in channels -> true
      true -> parent(state, channel) in channels
    end
  end

  defp parent(state, channel) do
    case state.channels[channel] do
      %{parent: parent} when is_binary(parent) -> parent
      _unknown -> nil
    end
  end

  defp author_label(author, channel) do
    name =
      [author["global_name"], author["username"]]
      |> Enum.find("someone", &(is_binary(&1) and &1 != ""))

    case channel do
      %{name: channel_name} when is_binary(channel_name) -> "#{name} (##{channel_name})"
      _unknown -> name
    end
  end

  # Discord writes mentions as ids (<@123>, <#456>); show them as names.
  @doc false
  def readable(content, message, state) do
    users =
      for %{"id" => id} = user <- List.wrap(message["mentions"]), into: %{} do
        {id, user["global_name"] || user["username"] || "user"}
      end

    content
    |> replace(~r/<@!?(\d{1,20})>/, fn [_all, id] -> "@" <> Map.get(users, id, "user") end)
    |> replace(~r/<#(\d{1,20})>/, fn [_all, id] -> "#" <> channel_name(state, id) end)
    |> replace(~r/<@&\d{1,20}>/, fn _match -> "@role" end)
    |> replace(~r/<a?:(\w{1,32}):\d{1,20}>/, fn [_all, name] -> ":#{name}:" end)
  end

  defp replace(text, regex, fun),
    do: Regex.replace(regex, text, fn all, capture -> fun.([all, capture]) end)

  defp channel_name(state, id) do
    case state.channels[id] do
      %{name: name} when is_binary(name) -> name
      _unknown -> "channel"
    end
  end

  defp timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp timestamp(_other), do: DateTime.utc_now()

  # --- name caches ----------------------------------------------------------------

  defp put_guild(state, guild, name) when is_binary(guild) and is_binary(name),
    do: %{state | guilds: bounded_put(state.guilds, guild, name)}

  defp put_guild(state, _guild, _name), do: state

  defp put_channel(state, %{"id" => id} = channel) when is_binary(id) do
    entry = %{
      name: string_or_nil(channel["name"]),
      guild: string_or_nil(channel["guild_id"]),
      parent: string_or_nil(channel["parent_id"])
    }

    %{state | channels: bounded_put(state.channels, id, entry)}
  end

  defp put_channel(state, _channel), do: state

  # Crude but bounded: a cache that reaches the cap starts again, and
  # refills as Discord sends guild and channel events.
  defp bounded_put(map, key, value) do
    map = if map_size(map) >= @max_cached and not Map.has_key?(map, key), do: %{}, else: map
    Map.put(map, key, value)
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  # --- position and catch-up --------------------------------------------------------

  # Every message reaching the bot moves its channel's position, matched
  # or not, so a catch-up never re-reads what was already seen.
  defp remember_position(state, %{"id" => id, "channel_id" => channel, "guild_id" => guild}) do
    if Enum.all?([id, channel, guild], &snowflake?/1) and allowed?(state, guild, channel),
      do: advance(state, channel, guild, id),
      else: state
  end

  defp remember_position(state, _message), do: state

  defp advance(state, channel, guild, id) do
    last_seen =
      case state.last_seen[channel] do
        {_guild, seen} ->
          if newer?(id, seen),
            do: Map.put(state.last_seen, channel, {guild, id}),
            else: state.last_seen

        nil ->
          Map.put(state.last_seen, channel, {guild, id})
      end

    %{state | last_seen: trim(last_seen, 2 * @max_saved_channels)}
  end

  # Snowflakes grow with time; compare them as numbers, not strings.
  defp newer?(a, b), do: String.to_integer(a) > String.to_integer(b)

  # The channels with the most recent activity.
  defp trim(last_seen, max) when map_size(last_seen) <= max, do: last_seen

  defp trim(last_seen, _max) do
    last_seen
    |> Enum.sort_by(fn {_channel, {_guild, id}} -> String.to_integer(id) end, :desc)
    |> Enum.take(@max_saved_channels)
    |> Map.new()
  end

  # Positions are taken now: live messages arriving before the fetch moves
  # last_seen on, and fetching from there would skip the gap.
  defp queue_catch_up(state) do
    queue =
      for {channel, {guild, after_id}} <- state.last_seen,
          allowed?(state, guild, channel),
          do: %{channel: channel, guild: guild, after: after_id, pages: 0}

    %{state | catch_up: queue}
  end

  @impl true
  def tick(%State{} = state) do
    {posts, state} = catch_up(state)
    now = System.monotonic_time(:millisecond)

    state =
      if state.last_save_mono == nil or now - state.last_save_mono >= @save_every_ms,
        do: save_cursor(%{state | last_save_mono: now}),
        else: state

    {posts, state}
  end

  defp catch_up(%State{catch_up: []} = state), do: {[], state}

  defp catch_up(state) do
    if waiting?(state) do
      {[], state}
    else
      Enum.reduce(1..@catch_up_per_tick, {[], state}, fn _turn, {posts, state} ->
        case state.catch_up do
          [item | rest] ->
            if waiting?(state) do
              {posts, state}
            else
              {more, state} = fetch_channel(item, %{state | catch_up: rest})
              {posts ++ more, state}
            end

          [] ->
            {posts, state}
        end
      end)
    end
  end

  defp waiting?(%State{wait_until_mono: nil}), do: false
  defp waiting?(state), do: System.monotonic_time(:millisecond) < state.wait_until_mono

  defp fetch_channel(item, state) do
    request =
      Req.new(
        [
          url: "#{@api_url}/channels/#{item.channel}/messages",
          params: [after: item.after, limit: @catch_up_page],
          headers: [{"authorization", "Bot " <> state.token}],
          receive_timeout: 5_000,
          connect_options: [timeout: 5_000],
          retry: false
        ] ++ Keyword.get(settings(), :req_options, [])
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: messages} = response} when is_list(messages) ->
        state = rate_limit(state, response)
        caught_up(item, messages, state)

      {:ok, %{status: 429, body: body} = response} ->
        retry_after = if is_map(body), do: body["retry_after"], else: nil
        ms = seconds_to_ms(retry_after || header(response, "retry-after")) || 5_000
        {[], %{state | catch_up: [item | state.catch_up], wait_until_mono: now() + ms}}

      {:ok, %{status: 401}} ->
        if not state.unauthorized_logged?,
          do: Logger.warning("discord: catch-up refused (HTTP 401); check DISCORD_BOT_TOKEN")

        {[], %{state | catch_up: [], unauthorized_logged?: true}}

      {:ok, %{status: status}} ->
        # 403: no access any more; 404: the channel is gone. Either way,
        # nothing to fetch there.
        Logger.debug("discord: catch-up for channel #{item.channel} returned HTTP #{status}")
        {[], state}

      {:error, reason} ->
        Logger.debug("discord: catch-up for channel #{item.channel} failed: #{error(reason)}")
        {[], state}
    end
  end

  defp caught_up(item, messages, state) do
    messages =
      messages
      |> Enum.filter(&(is_map(&1) and snowflake?(&1["id"])))
      |> Enum.map(&Map.merge(&1, %{"guild_id" => item.guild, "channel_id" => item.channel}))
      |> Enum.sort_by(&String.to_integer(&1["id"]))

    state = Enum.reduce(messages, state, &remember_position(&2, &1))
    posts = messages |> Enum.map(&post(&1, state)) |> Enum.reject(&is_nil/1)

    # A full page may mean more after it.
    state =
      case List.last(messages) do
        %{"id" => newest} when length(messages) == @catch_up_page ->
          if item.pages + 1 < @catch_up_max_pages do
            next = %{item | after: newest, pages: item.pages + 1}
            %{state | catch_up: state.catch_up ++ [next]}
          else
            state
          end

        _fewer ->
          state
      end

    {posts, state}
  end

  defp rate_limit(state, response) do
    with "0" <- header(response, "x-ratelimit-remaining"),
         ms when is_integer(ms) <- seconds_to_ms(header(response, "x-ratelimit-reset-after")) do
      %{state | wait_until_mono: now() + ms}
    else
      _plenty -> state
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp seconds_to_ms(seconds) when is_number(seconds) and seconds >= 0,
    do: min(round(seconds * 1000), 60_000)

  defp seconds_to_ms(seconds) when is_binary(seconds) do
    case Float.parse(seconds) do
      {value, _rest} -> seconds_to_ms(value)
      :error -> nil
    end
  end

  defp seconds_to_ms(_seconds), do: nil

  defp now, do: System.monotonic_time(:millisecond)

  # Only the error itself: never the request, which carries the token.
  defp error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error(reason), do: inspect(reason)

  # --- the cursor file ------------------------------------------------------------

  defp cursor_file do
    case Keyword.fetch(settings(), :cursor_file) do
      {:ok, file} -> file
      :error -> CursorFile.default_path("discord.cursor")
    end
  end

  defp read_last_seen(file) do
    with contents when is_binary(contents) <- CursorFile.read(file),
         {:ok, %{"channels" => channels}} when is_map(channels) <- Jason.decode(contents) do
      for {channel, %{"guild" => guild, "last" => last}} <- channels,
          Enum.all?([channel, guild, last], &snowflake?/1),
          into: %{},
          do: {channel, {guild, last}}
    else
      _missing_or_bad -> %{}
    end
  end

  defp save_cursor(%State{cursor_file: nil} = state), do: state
  defp save_cursor(%State{last_seen: same, saved: same} = state), do: state

  defp save_cursor(state) do
    last_seen = trim(state.last_seen, @max_saved_channels)

    channels =
      Map.new(last_seen, fn {channel, {guild, last}} ->
        {channel, %{guild: guild, last: last}}
      end)

    case CursorFile.write(state.cursor_file, Jason.encode!(%{version: 1, channels: channels})) do
      :ok ->
        %{state | last_seen: last_seen, saved: last_seen}

      {:error, reason} ->
        Logger.warning("discord: could not save the stream position: #{inspect(reason)}")
        state
    end
  end

  defp settings, do: Application.get_env(:smm_monitor, __MODULE__, [])
end
