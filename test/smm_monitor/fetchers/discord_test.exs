defmodule SmmMonitor.Fetchers.DiscordTest do
  @moduledoc """
  Discord's Gateway handling, message mapping and catch-up, and the bot
  end to end against a WebSocket server on 127.0.0.1.

  Nothing leaves the machine: the Gateway is `SmmMonitor.FakeWsServer`
  (through the test-only `gateway_url` setting) and the REST API is
  `SmmMonitor.DiscordStub`.
  """

  use SmmMonitor.ClientCase, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.{DiscordStub, FakeWsServer, Monitor}
  alias SmmMonitor.Fetchers.{CursorFile, Discord, StreamWorker}
  alias SmmMonitor.Fetchers.Discord.State

  @token "Bot-token.very-secret"
  @guild "100000000000000001"
  @channel "200000000000000002"
  @thread "300000000000000003"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    saved =
      for key <- [Discord, :credentials, :mock_platforms],
          do: {key, Application.get_env(:smm_monitor, key)}

    Application.put_env(:smm_monitor, Discord,
      cursor_file: Path.join(dir, "discord.cursor"),
      req_options: DiscordStub.req_options()
    )

    Application.put_env(:smm_monitor, :credentials, discord: [bot_token: @token])
    Application.put_env(:smm_monitor, :mock_platforms, discord: false)

    on_exit(fn ->
      for {key, value} <- saved do
        if value,
          do: Application.put_env(:smm_monitor, key, value),
          else: Application.delete_env(:smm_monitor, key)
      end
    end)

    :ok
  end

  describe "configuration" do
    test "is ready only with a bot token" do
      assert Discord.ready?(%{credentials: [bot_token: "abc"]})
      refute Discord.ready?(%{credentials: [bot_token: "  "]})
      refute Discord.ready?(%{credentials: []})
    end

    test "connects to Discord's gateway, or the session's resume host" do
      assert {:ok, "wss://gateway.discord.gg/?v=10&encoding=json"} =
               Discord.url(%{}, new_state())

      resuming = %{
        new_state()
        | session_id: "s",
          resume_url: "wss://gateway-us-east1-b.discord.gg"
      }

      assert {:ok, "wss://gateway-us-east1-b.discord.gg/?v=10&encoding=json"} =
               Discord.url(%{}, resuming)

      # Without a session there is nothing to resume, wherever it was.
      assert {:ok, "wss://gateway.discord.gg/" <> _query} =
               Discord.url(%{}, %{resuming | session_id: nil})
    end

    test "only takes a resume host that is Discord's" do
      assert Discord.resume_url("wss://gateway-us-east1-b.discord.gg") ==
               "wss://gateway-us-east1-b.discord.gg"

      assert Discord.resume_url("wss://gateway.discord.gg/?v=10") == "wss://gateway.discord.gg"

      for bad <- [
            "ws://gateway.discord.gg",
            "wss://discord.gg.evil.example",
            "wss://evil-discord.gg",
            "wss://user@gateway.discord.gg",
            "https://gateway.discord.gg",
            nil,
            42
          ] do
        assert Discord.resume_url(bad) == nil, "accepted #{inspect(bad)}"
      end
    end

    test "allows big messages: a large server's GUILD_CREATE is several MB" do
      assert Discord.max_message_bytes() == 8 * 1_048_576
    end
  end

  describe "the Gateway handshake" do
    test "Hello is answered with Identify, asking for message content" do
      {:ok, [], [frame], state} = Discord.handle_message(hello(40_000), new_state())

      assert %{"op" => 2, "d" => identify} = Jason.decode!(frame)
      assert identify["token"] == @token
      assert identify["intents"] == 33_281
      assert identify["properties"]["browser"] == "smm_monitor"

      # The first beat lands somewhere in the interval, then every interval.
      assert state.next_beat_ms in 1..40_000
      assert state.heartbeat_interval == 40_000
    end

    test "Hello is answered with Resume when there is a session" do
      state = %{new_state() | session_id: "abc", seq: 42}
      {:ok, [], [frame], _state} = Discord.handle_message(hello(40_000), state)

      assert Jason.decode!(frame) == %{
               "op" => 6,
               "d" => %{"token" => @token, "session_id" => "abc", "seq" => 42}
             }
    end

    test "READY stores the session and only a Discord resume host" do
      {:ok, [], [], state} =
        Discord.handle_message(
          dispatch("READY", 1, %{
            "session_id" => "sess",
            "resume_gateway_url" => "wss://gateway-us-east1-c.discord.gg",
            "guilds" => [%{"id" => @guild, "unavailable" => true}]
          }),
          new_state()
        )

      assert state.session_id == "sess"
      assert state.resume_url == "wss://gateway-us-east1-c.discord.gg"
      assert state.seq == 1

      {:ok, [], [], state} =
        Discord.handle_message(
          dispatch("READY", 2, %{"session_id" => "x", "resume_gateway_url" => "wss://evil.test"}),
          state
        )

      assert state.resume_url == nil
    end

    test "READY in no server says how to invite the bot" do
      log =
        capture_log(fn ->
          Discord.handle_message(
            dispatch("READY", 1, %{"session_id" => "s", "guilds" => []}),
            new_state()
          )
        end)

      assert log =~ "not in any server"
    end
  end

  describe "heartbeat" do
    test "beats with the last sequence number and needs an ack before the next" do
      {:ok, [], [_identify], state} = Discord.handle_message(hello(40_000), new_state())
      {:ok, [], [], state} = Discord.handle_message(dispatch("GUILD_UPDATE", 7, %{}), state)

      {[frame], state} = Discord.heartbeat(state)
      assert Jason.decode!(frame) == %{"op" => 1, "d" => 7}
      assert Discord.heartbeat_ms(state) == 40_000

      # No ack: the connection is a zombie.
      assert {:reconnect, _state} = Discord.heartbeat(state)

      {:ok, [], [], state} = Discord.handle_message(%{"op" => 11}, state)
      assert {[_frame], _state} = Discord.heartbeat(state)
    end

    test "Discord asking for a beat gets one at once" do
      state = %{new_state() | seq: 3}
      assert {:ok, [], [frame], _state} = Discord.handle_message(%{"op" => 1}, state)
      assert Jason.decode!(frame) == %{"op" => 1, "d" => 3}
    end

    test "a new connection waits for Hello before beating" do
      {:ok, [], [_identify], state} = Discord.handle_message(hello(40_000), new_state())
      {[_beat], state} = Discord.heartbeat(state)

      state = Discord.on_disconnect(state)
      {[], state} = Discord.on_open(state)

      assert Discord.heartbeat_ms(state) == nil
      assert state.acked?
    end
  end

  describe "reconnecting" do
    test "Reconnect and a resumable Invalid Session keep the session" do
      state = %{new_state() | session_id: "s", seq: 5}

      assert {:reconnect, %{session_id: "s"}} = Discord.handle_message(%{"op" => 7}, state)

      assert {:reconnect, %{session_id: "s"}} =
               Discord.handle_message(%{"op" => 9, "d" => true}, state)
    end

    test "an Invalid Session that cannot resume starts afresh" do
      state = %{new_state() | session_id: "s", seq: 5, resume_url: "wss://a.discord.gg"}

      assert {:reconnect, %{session_id: nil, seq: nil, resume_url: nil}} =
               Discord.handle_message(%{"op" => 9, "d" => false}, state)
    end

    test "closes with 4000 while there is a session, so it can be resumed" do
      assert Discord.close_code(new_state()) == 1000
      assert Discord.close_code(%{new_state() | session_id: "s"}) == 4000
    end

    test "close codes a retry will not fix stop the bot" do
      for {code, text} <- [
            {4004, "DISCORD_BOT_TOKEN"},
            {4014, "Message Content Intent"},
            {4010, "sharding"},
            {4011, "sharding"},
            {4012, "bug"},
            {4013, "bug"}
          ] do
        assert {:stop, reason, _state} = Discord.handle_close(code, new_state())
        assert reason =~ text
      end
    end

    test "other close codes reconnect, starting afresh only when the session is gone" do
      state = %{new_state() | session_id: "s", seq: 9}

      for code <- [4007, 4009],
          do: assert({:reconnect, %{session_id: nil}} = Discord.handle_close(code, state))

      for code <- [nil, 1000, 1001, 1006, 4000, 4008],
          do: assert({:reconnect, %{session_id: "s"}} = Discord.handle_close(code, state))
    end
  end

  describe "messages" do
    test "a message becomes a post with a discord.com link" do
      state = with_channel(new_state())
      {:ok, [post], [], _state} = Discord.handle_message(message_create(), state)

      assert post.id == "400000000000000004"
      assert post.platform == :discord
      assert post.author == "Maya (#general)"
      assert post.text == "I love Acme"
      assert post.url == "https://discord.com/channels/#{@guild}/#{@channel}/400000000000000004"
      assert post.timestamp == ~U[2026-11-12 10:00:00.000000Z]
    end

    test "without a known channel the author is just the name" do
      message = message_create(%{"author" => %{"username" => "maya_99", "global_name" => nil}})
      {:ok, [post], [], _state} = Discord.handle_message(message, new_state())

      assert post.author == "maya_99"
    end

    test "mentions, channels, roles and emoji read as names" do
      state = with_channel(new_state())

      message =
        message_create(%{
          "content" =>
            "<@500000000000000005> <@!500000000000000005> see <#200000000000000002> " <>
              "<@&600000000000000006> <:acme:700000000000000007> <a:party:700000000000000008> " <>
              "<#999999999999999999> <@123>",
          "mentions" => [%{"id" => "500000000000000005", "username" => "owen"}]
        })

      {:ok, [post], [], _state} = Discord.handle_message(message, state)

      assert post.text ==
               "@owen @owen see #general @role :acme: :party: #channel @user"
    end

    test "messages that are not someone talking are skipped" do
      state = with_channel(new_state())

      for {why, change} <- [
            dm: %{"guild_id" => nil},
            bot: %{"author" => %{"username" => "b", "bot" => true}},
            webhook: %{"webhook_id" => "800000000000000008"},
            system: %{"type" => 7},
            empty: %{"content" => "  "},
            bad_id: %{"id" => "4/../../evil"},
            bad_channel: %{"channel_id" => "general"},
            no_author: %{"author" => nil}
          ] do
        assert {:ok, [], [], _state} = Discord.handle_message(message_create(change), state),
               "did not skip #{why}"
      end

      # A reply is a message like any other.
      assert {:ok, [_post], [], _state} =
               Discord.handle_message(message_create(%{"type" => 19}), state)
    end

    test "the allow-list keeps listed servers and channels, and threads of listed channels" do
      state =
        new_state()
        |> with_channel()
        |> then(fn state ->
          {:ok, [], [], state} =
            Discord.handle_message(
              dispatch("THREAD_CREATE", 2, %{
                "id" => @thread,
                "guild_id" => @guild,
                "parent_id" => @channel,
                "name" => "help"
              }),
              state
            )

          state
        end)

      other_channel = "200000000000000099"

      allow(channels: [@channel])
      assert Discord.allowed?(state, @guild, @channel)
      assert Discord.allowed?(state, @guild, @thread)
      refute Discord.allowed?(state, @guild, other_channel)
      # A thread whose parent is unknown cannot be shown to be allowed.
      refute Discord.allowed?(%{state | channels: %{}}, @guild, @thread)

      allow(guilds: [@guild])
      assert Discord.allowed?(state, @guild, other_channel)
      refute Discord.allowed?(state, "100000000000000077", other_channel)

      allow(guilds: [], channels: [])
      assert Discord.allowed?(state, "100000000000000077", other_channel)

      allow(channels: [other_channel])

      assert {:ok, [], [], _state} = Discord.handle_message(message_create(), state)
    end

    test "the name caches are bounded" do
      state =
        Enum.reduce(1..10_001, new_state(), fn n, state ->
          {:ok, [], [], state} =
            Discord.handle_message(
              dispatch("CHANNEL_CREATE", n, %{"id" => Integer.to_string(n), "name" => "c"}),
              state
            )

          state
        end)

      assert map_size(state.channels) <= 10_000
    end

    test "guild and channel events keep the names up to date" do
      state = with_channel(new_state())
      assert state.guilds[@guild] == "Acme Community"

      {:ok, [], [], state} =
        Discord.handle_message(
          dispatch("GUILD_UPDATE", 2, %{"id" => @guild, "name" => "Acme HQ"}),
          state
        )

      assert state.guilds[@guild] == "Acme HQ"

      {:ok, [], [], state} =
        Discord.handle_message(dispatch("CHANNEL_DELETE", 3, %{"id" => @channel}), state)

      refute Map.has_key?(state.channels, @channel)

      {:ok, [], [], state} =
        Discord.handle_message(dispatch("GUILD_DELETE", 4, %{"id" => @guild}), state)

      refute Map.has_key?(state.guilds, @guild)
    end
  end

  describe "catching up after an outage" do
    setup %{tmp_dir: dir} do
      cursor = Path.join(dir, "discord.cursor")

      CursorFile.write(
        cursor,
        Jason.encode!(%{
          version: 1,
          channels: %{@channel => %{guild: @guild, last: "400000000000000000"}}
        })
      )

      :ok
    end

    test "after READY, asks each known channel for what it missed" do
      DiscordStub.install(fn _request ->
        {200,
         [
           rest_message("400000000000000010", "Acme is down?"),
           rest_message("400000000000000009", "unrelated")
         ]}
      end)

      state = ready(init())
      # A live message arriving first must not move the catch-up's start.
      {:ok, [_post], [], state} =
        Discord.handle_message(message_create(%{"id" => "400000000000000020"}), state)

      {posts, state} = Discord.tick(state)

      assert_received {:discord_request, request}
      assert request.url.path == "/api/v10/channels/#{@channel}/messages"

      assert URI.decode_query(request.url.query) == %{
               "after" => "400000000000000000",
               "limit" => "100"
             }

      assert Req.Request.get_header(request, "authorization") == ["Bot " <> @token]

      assert Enum.map(posts, & &1.id) == ["400000000000000009", "400000000000000010"]
      assert Enum.all?(posts, &(&1.url =~ "https://discord.com/channels/#{@guild}/#{@channel}/"))
      assert state.catch_up == []
      # The live message stays the newest seen.
      assert state.last_seen[@channel] == {@guild, "400000000000000020"}
    end

    test "a resumed session needs no catch-up" do
      DiscordStub.install(fn _request -> flunk("no request expected") end)

      {:ok, [], [], state} = Discord.handle_message(dispatch("RESUMED", 5, %{}), init())
      assert {[], _state} = Discord.tick(state)
    end

    test "a full page asks for the next" do
      page = for n <- 1..100, do: rest_message(Integer.to_string(400_000_000_000_000_000 + n), "x")

      DiscordStub.install(fn request ->
        if URI.decode_query(request.url.query)["after"] == "400000000000000000",
          do: {200, page},
          else: {200, []}
      end)

      {_posts, state} = Discord.tick(ready(init()))

      assert_received {:discord_request, _first}
      assert_received {:discord_request, second}
      assert URI.decode_query(second.url.query)["after"] == "400000000000000100"
      assert state.catch_up == []
    end

    test "waits out a rate limit and tries the channel again" do
      DiscordStub.install(fn _request -> {429, %{"retry_after" => 30.0}} end)

      {[], state} = Discord.tick(ready(init()))
      assert [%{channel: @channel}] = state.catch_up

      # Still waiting: no request.
      DiscordStub.install(fn _request -> flunk("no request while rate limited") end)
      {[], _state} = Discord.tick(state)
    end

    test "an exhausted bucket waits before the next request" do
      second = "200000000000000022"

      DiscordStub.install(fn _request ->
        {200, [], [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset-after", "2.5"}]}
      end)

      state = %{
        ready(init())
        | catch_up: [
            %{channel: @channel, guild: @guild, after: "1", pages: 0},
            %{channel: second, guild: @guild, after: "1", pages: 0}
          ]
      }

      {[], state} = Discord.tick(state)
      assert [%{channel: ^second}] = state.catch_up
      assert state.wait_until_mono > System.monotonic_time(:millisecond)
    end

    test "a channel it cannot read is dropped; a bad token stops the catch-up" do
      DiscordStub.install(fn _request -> {403, %{"message" => "Missing Access"}} end)
      {[], state} = Discord.tick(ready(init()))
      assert state.catch_up == []

      DiscordStub.install(fn _request -> {401, %{"message" => "401: Unauthorized"}} end)

      state = %{
        state
        | catch_up: for(n <- 1..3, do: %{channel: "#{n}", guild: @guild, after: "1", pages: 0})
      }

      log = capture_log(fn -> send(self(), {:result, Discord.tick(state)}) end)
      assert_received {:result, {[], state}}
      assert state.catch_up == []
      assert log =~ "HTTP 401"
      refute log =~ @token
    end

    test "the position is saved privately and read back", %{tmp_dir: dir} do
      DiscordStub.install(fn _request -> {200, []} end)
      state = ready(init())

      {:ok, [_post], [], state} =
        Discord.handle_message(message_create(%{"id" => "400000000000000050"}), state)

      _state = Discord.on_disconnect(state)

      path = Path.join(dir, "discord.cursor")
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      refute File.read!(path) =~ @token

      assert init().last_seen == %{@channel => {@guild, "400000000000000050"}}
    end
  end

  describe "end to end" do
    setup %{tmp_dir: dir} do
      Monitor.reset()
      server = FakeWsServer.start()

      Application.put_env(:smm_monitor, Discord,
        gateway_url: server.url,
        cursor_file: Path.join(dir, "discord.cursor"),
        req_options: DiscordStub.req_options()
      )

      set_clients(["Acme"])
      :ok
    end

    test "identifies, stores matching messages and resumes after a drop" do
      log =
        capture_log(fn ->
          start_worker()
          conn = FakeWsServer.await_connection()

          FakeWsServer.send_text(conn, Jason.encode!(hello(45_000)))
          assert_receive {:fake_ws_frame, ^conn, 1, identify}, 1_000
          assert %{"op" => 2, "d" => %{"token" => @token}} = Jason.decode!(identify)

          FakeWsServer.send_text(
            conn,
            Jason.encode!(
              dispatch("READY", 1, %{
                "session_id" => "session-1",
                "resume_gateway_url" => "wss://gateway-us-east1-b.discord.gg",
                "guilds" => []
              })
            )
          )

          FakeWsServer.send_text(conn, Jason.encode!(message_create(%{"s" => 2})))

          FakeWsServer.send_text(
            conn,
            Jason.encode!(
              message_create(%{"s" => 3, "id" => "400000000000000005", "content" => "nothing here"})
            )
          )

          assert eventually(fn -> Monitor.recent(:all, 100, "acme") != [] end)

          assert [%{platform: :discord, id: "400000000000000004"}] =
                   Monitor.recent(:all, 100, "acme")

          # Discord drops the connection; the bot resumes where it was.
          FakeWsServer.close(conn, 1001)
          conn = FakeWsServer.await_connection(4_000)
          FakeWsServer.send_text(conn, Jason.encode!(hello(45_000)))
          assert_receive {:fake_ws_frame, ^conn, 1, resume}, 1_000

          assert Jason.decode!(resume) == %{
                   "op" => 6,
                   "d" => %{"token" => @token, "session_id" => "session-1", "seq" => 3}
                 }

          status = StreamWorker.status(:discord)
          refute inspect(status, limit: :infinity) =~ @token
          refute inspect(:sys.get_status(StreamWorker.name(:discord)), limit: :infinity) =~ @token
        end)

      refute log =~ @token
    end

    test "a refused token stops the bot with a message that says what to fix" do
      capture_log(fn ->
        start_worker()
        conn = FakeWsServer.await_connection()
        FakeWsServer.close(conn, 4004)

        assert eventually(fn -> StreamWorker.status(:discord).connection == :stopped end)
      end)

      assert StreamWorker.status(:discord).last_error =~ "DISCORD_BOT_TOKEN"
      refute_receive {:fake_ws_connected, _conn, _request}, 2_500
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp new_state, do: %State{token: @token}

  defp init, do: Discord.init_state(%{credentials: [bot_token: @token]})

  defp ready(state) do
    {:ok, [], [], state} =
      Discord.handle_message(
        dispatch("READY", 1, %{"session_id" => "s", "guilds" => [%{"id" => @guild}]}),
        state
      )

    state
  end

  defp with_channel(state) do
    {:ok, [], [], state} =
      Discord.handle_message(
        dispatch("GUILD_CREATE", 1, %{
          "id" => @guild,
          "name" => "Acme Community",
          "channels" => [%{"id" => @channel, "name" => "general", "type" => 0}],
          "threads" => []
        }),
        state
      )

    state
  end

  defp allow(lists) do
    settings = Application.get_env(:smm_monitor, Discord, [])
    Application.put_env(:smm_monitor, Discord, Keyword.merge(settings, lists))
  end

  defp hello(interval), do: %{"op" => 10, "d" => %{"heartbeat_interval" => interval}}

  defp dispatch(event, seq, data), do: %{"op" => 0, "t" => event, "s" => seq, "d" => data}

  defp message_create(changes \\ %{}) do
    {seq, changes} = Map.pop(changes, "s", 2)

    message =
      Map.merge(
        %{
          "id" => "400000000000000004",
          "channel_id" => @channel,
          "guild_id" => @guild,
          "type" => 0,
          "content" => "I love Acme",
          "timestamp" => "2026-11-12T10:00:00.000000+00:00",
          "author" => %{"id" => "500000000000000001", "username" => "maya", "global_name" => "Maya"},
          "mentions" => []
        },
        changes
      )

    dispatch("MESSAGE_CREATE", seq, message)
  end

  # REST messages carry no guild_id.
  defp rest_message(id, content) do
    %{
      "id" => id,
      "channel_id" => @channel,
      "type" => 0,
      "content" => content,
      "timestamp" => "2026-11-12T09:00:00.000000+00:00",
      "author" => %{"id" => "500000000000000001", "username" => "maya"}
    }
  end

  defp start_worker do
    start_supervised!({StreamWorker, module: Discord})
    StreamWorker.poll_now(:discord)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(30)
      eventually(check, attempts - 1)
    end
  end
end
