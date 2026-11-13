defmodule SmmMonitor.Fetchers.MastodonTest do
  @moduledoc """
  Mastodon's streaming messages, status mapping, finding the streaming
  host and catch-up, and the stream end to end against a WebSocket server
  on 127.0.0.1.

  Nothing leaves the machine: the streaming API is `SmmMonitor.FakeWsServer`
  (through the `streaming_url` setting) and the REST API is
  `SmmMonitor.MastodonStub`.
  """

  use SmmMonitor.ClientCase, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias SmmMonitor.{FakeWsServer, MastodonStub, Monitor}
  alias SmmMonitor.Fetchers.{CursorFile, Mastodon, StreamWorker}

  doctest Mastodon

  @token "mastodon-token.very-secret"
  @instance "mastodon.example"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    saved =
      for key <- [Mastodon, :credentials, :mock_platforms],
          do: {key, Application.get_env(:smm_monitor, key)}

    Application.put_env(:smm_monitor, Mastodon,
      instance: @instance,
      cursor_file: Path.join(dir, "mastodon.cursor"),
      req_options: MastodonStub.req_options()
    )

    Application.put_env(:smm_monitor, :credentials, mastodon: [access_token: @token])
    Application.put_env(:smm_monitor, :mock_platforms, mastodon: false)

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
    test "is ready only with a token and a server" do
      assert Mastodon.ready?(%{credentials: [access_token: "abc"]})
      refute Mastodon.ready?(%{credentials: [access_token: "  "]})
      refute Mastodon.ready?(%{credentials: []})

      settings(instance: nil)
      refute Mastodon.ready?(%{credentials: [access_token: "abc"]})

      settings(instance: "not a host")
      refute Mastodon.ready?(%{credentials: [access_token: "abc"]})
    end

    test "asks the server where its streaming API is" do
      MastodonStub.install(fn _request ->
        {200,
         %{"configuration" => %{"urls" => %{"streaming" => "wss://streaming.mastodon.example"}}}}
      end)

      assert {:ok, state} = Mastodon.prepare(%{}, init())
      assert state.streaming_url == "wss://streaming.mastodon.example/api/v1/streaming"

      assert_received {:mastodon_request, request}
      assert URI.to_string(request.url) == "https://mastodon.example/api/v2/instance"
      # The lookup is public; the token is not sent with it.
      assert Req.Request.get_header(request, "authorization") == []
    end

    test "keeps what it found rather than asking before every connection" do
      MastodonStub.install(fn _request -> flunk("no request expected") end)
      state = %{init() | streaming_url: "wss://streaming.mastodon.example/api/v1/streaming"}

      assert {:ok, ^state} = Mastodon.prepare(%{}, state)
    end

    test "falls back to the server itself when the lookup does not say" do
      for answer <- [{404, %{"error" => "Not found"}}, {200, %{"configuration" => %{}}}, {500, ""}] do
        MastodonStub.install(fn _request -> answer end)

        assert {:ok, state} = capture(fn -> Mastodon.prepare(%{}, init()) end)
        assert state.streaming_url == "wss://mastodon.example/api/v1/streaming"
      end
    end

    test "refuses a streaming host that is not wss://" do
      for url <- ["ws://streaming.mastodon.example", "http://streaming.mastodon.example", "nope"] do
        MastodonStub.install(fn _request ->
          {200, %{"configuration" => %{"urls" => %{"streaming" => url}}}}
        end)

        assert {:ok, state} = capture(fn -> Mastodon.prepare(%{}, init()) end)
        assert state.streaming_url == "wss://mastodon.example/api/v1/streaming"
      end
    end

    test "SMM_MASTODON_STREAMING_URL wins over the lookup" do
      settings(streaming_url: "wss://stream.example/api/v1/streaming/")
      MastodonStub.install(fn _request -> flunk("no request expected") end)

      assert {:ok, state} = Mastodon.prepare(%{}, init())
      assert state.streaming_url == "wss://stream.example/api/v1/streaming"
      assert {:ok, "wss://stream.example/api/v1/streaming"} = Mastodon.url(%{}, state)
    end

    test "the token goes in a header, never in the URL" do
      state = %{init() | streaming_url: "wss://streaming.mastodon.example/api/v1/streaming"}

      assert Mastodon.headers(state) == [{"authorization", "Bearer " <> @token}]
      {:ok, url} = Mastodon.url(%{}, state)
      refute url =~ @token
    end

    test "subscribes to the federated timeline, or the local one when asked" do
      assert {[frame], _state} = Mastodon.on_open(init())
      assert Jason.decode!(frame) == %{"type" => "subscribe", "stream" => "public"}

      settings(timeline: :local)
      assert {[frame], _state} = Mastodon.on_open(init())
      assert Jason.decode!(frame) == %{"type" => "subscribe", "stream" => "public:local"}
    end

    test "the token stays out of inspect" do
      refute inspect(init()) =~ @token
    end
  end

  describe "statuses to posts" do
    test "a local post: id, author, link on the server, and plain text" do
      [local | _rest] = fixture()

      assert Mastodon.post(local, @instance) == %{
               id: "mastodon-mastodon.example-113456789012345678",
               platform: :mastodon,
               author: "@maya@mastodon.example",
               text: "Switched our team to #Acme & it's been great. Thanks @ops more soon",
               url: "https://mastodon.example/@maya/113456789012345678",
               timestamp: ~U[2026-11-12 09:30:00.000Z]
             }
    end

    test "a post from another server keeps its address, opens on ours, and leads with its CW" do
      [_local, remote | _rest] = fixture()
      post = Mastodon.post(remote, @instance)

      assert post.author == "@owen@fosstodon.example"
      assert post.url == "https://mastodon.example/@owen@fosstodon.example/113456789012345690"
      assert post.text == "[CW: Acme rant] Their https://acme.example/pricing page is <confusing>"
    end

    test "boosts are skipped: the original arrives in its own right" do
      [_local, _remote, boost] = fixture()

      assert Mastodon.post(boost, @instance) == nil
    end

    test "anything not public is skipped" do
      [local | _rest] = fixture()

      for visibility <- ["unlisted", "private", "direct", nil] do
        assert Mastodon.post(%{local | "visibility" => visibility}, @instance) == nil
      end
    end

    test "a malformed id or account is dropped rather than linked to" do
      [local | _rest] = fixture()

      assert Mastodon.post(%{local | "id" => "../../evil"}, @instance) == nil
      assert Mastodon.post(%{local | "id" => 123}, @instance) == nil

      for acct <- ["", "maya/../x", "maya@evil.example/path", "<script>", nil] do
        status = put_in(local, ["account", "acct"], acct)
        assert Mastodon.post(status, @instance) == nil
      end
    end

    test "a post with no text (a picture alone) has nothing to match" do
      [local | _rest] = fixture()

      assert Mastodon.post(%{local | "content" => "<p></p>"}, @instance) == nil
    end

    test "a post dated in the future is dated now" do
      [local | _rest] = fixture()
      post = Mastodon.post(%{local | "created_at" => "2099-01-01T00:00:00.000Z"}, @instance)

      assert DateTime.diff(DateTime.utc_now(), post.timestamp) in 0..5
    end

    test "HTML entities are decoded, and nonsense ones dropped" do
      assert SmmMonitor.Text.html_to_text("caf&#233; &#x1F600; &eacute; &#0; &#xD800;") ==
               "café 😀 &eacute;"

      assert SmmMonitor.Text.html_to_text(nil) == ""
    end
  end

  describe "stream messages" do
    test "an update becomes a post and moves the position on" do
      [local | _rest] = fixture()

      assert {:ok, [post], [], state} = Mastodon.handle_message(update(local), init())
      assert post.author == "@maya@mastodon.example"
      assert state.cursor == "113456789012345678"
    end

    test "a status that is skipped still moves the position on" do
      [_local, _remote, boost] = fixture()

      assert {:ok, [], [], state} = Mastodon.handle_message(update(boost), init())
      assert state.cursor == "113456789012345700"
    end

    test "the position never moves back, or into the future" do
      [local | _rest] = fixture()
      state = %{init() | cursor: "113456789012345690"}

      assert {:ok, _posts, [], %{cursor: "113456789012345690"}} =
               Mastodon.handle_message(update(local), state)

      future = id_at(System.os_time(:millisecond) + 3_600_000)

      assert {:ok, _posts, [], %{cursor: "113456789012345690"}} =
               Mastodon.handle_message(update(%{local | "id" => future}), state)
    end

    test "deletions, edits, notifications and nonsense are ignored" do
      state = init()

      for message <- [
            %{"event" => "delete", "payload" => "113456789012345678"},
            %{"event" => "status.update", "payload" => "{}"},
            %{"event" => "notification", "payload" => "{}"},
            %{"event" => "update", "payload" => "not json"},
            %{"event" => "update", "payload" => "[1,2]"},
            %{"something" => "else"}
          ] do
        assert {:ok, [], [], ^state} = Mastodon.handle_message(message, state)
      end
    end

    test "a refused stream stops, with what to fix" do
      log =
        capture_log(fn ->
          assert {:stop, reason, _state} =
                   Mastodon.handle_message(%{"error" => "Not authorized", "status" => 401}, init())

          assert reason =~ "MASTODON_ACCESS_TOKEN"
          assert reason =~ "read:statuses"

          assert {:stop, _reason, _state} =
                   Mastodon.handle_message(%{"error" => "Forbidden", "status" => 403}, init())
        end)

      refute log =~ @token
    end

    test "any other error reconnects" do
      capture_log(fn ->
        assert {:reconnect, _state} =
                 Mastodon.handle_message(%{"error" => "Oops", "status" => 500}, init())
      end)
    end
  end

  describe "a failed handshake" do
    test "a refused token stops" do
      for code <- ["401", "403"] do
        assert {:stop, reason, _state} =
                 Mastodon.handle_connect_error({:upgrade_refused, code}, init())

        assert reason =~ "MASTODON_ACCESS_TOKEN"
      end
    end

    test "a moved or missing streaming host is looked up again" do
      state = %{init() | streaming_url: "wss://old.example/api/v1/streaming"}

      for code <- ["301", "302", "404"] do
        assert {:reconnect, %{streaming_url: nil}} =
                 Mastodon.handle_connect_error({:upgrade_refused, code}, state)
      end
    end

    test "anything else is retried as it was" do
      state = %{init() | streaming_url: "wss://old.example/api/v1/streaming"}

      assert {:reconnect, ^state} = Mastodon.handle_connect_error({:upgrade_refused, "502"}, state)
      assert {:reconnect, ^state} = Mastodon.handle_connect_error(:timeout, state)
    end
  end

  describe "catching up after downtime" do
    test "asks for what came after the saved position" do
      cursor = id_at(minutes_ago(5))
      [local | _rest] = fixture()
      newer = %{local | "id" => id_at(minutes_ago(4))}

      MastodonStub.install(fn _request -> {200, [newer]} end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: cursor})
      {posts, state} = Mastodon.tick(state)

      assert_received {:mastodon_request, request}
      assert request.url.path == "/api/v1/timelines/public"
      assert request.url.host == @instance
      assert request.options[:params] == [min_id: cursor, limit: 40]
      assert Req.Request.get_header(request, "authorization") == ["Bearer " <> @token]

      assert [%{author: "@maya@mastodon.example"}] = posts
      assert state.cursor == newer["id"]
      assert state.catch_up == nil
    end

    test "the local timeline is asked for local posts" do
      settings(timeline: :local)
      MastodonStub.install(fn _request -> {200, []} end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(minutes_ago(5))})
      Mastodon.tick(state)

      assert_received {:mastodon_request, request}
      assert request.options[:params][:local] == true
    end

    test "pages on, two pages a tick, and stops after ten" do
      start = minutes_ago(30)
      test = self()
      counter = :counters.new(1, [])

      MastodonStub.install(fn request ->
        :counters.add(counter, 1, 1)
        send(test, {:page, request.options[:params][:min_id]})
        after_ms = String.to_integer(request.options[:params][:min_id]) >>> 16
        {200, full_page(after_ms)}
      end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(start)})

      {posts, state} = Mastodon.tick(state)
      assert :counters.get(counter, 1) == 2
      assert length(posts) == 80

      state = Enum.reduce(1..10, state, fn _tick, state -> state |> Mastodon.tick() |> elem(1) end)

      assert :counters.get(counter, 1) == 10
      assert state.catch_up == nil
    end

    test "nothing is caught up from a position over an hour old" do
      MastodonStub.install(fn _request -> flunk("no request expected") end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(minutes_ago(90))})

      assert state.catch_up == nil
      assert {[], _state} = Mastodon.tick(state)
    end

    test "waits out the rate limit" do
      reset = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

      MastodonStub.install(fn _request ->
        {200, full_page(minutes_ago(10)),
         [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", reset}]}
      end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(minutes_ago(10))})
      {_posts, state} = Mastodon.tick(state)

      assert_received {:mastodon_request, _request}
      refute_received {:mastodon_request, _request}

      MastodonStub.install(fn _request -> flunk("no request while rate limited") end)
      {[], state} = Mastodon.tick(state)

      assert state.catch_up != nil
    end

    test "a 429 waits and then tries the same page again" do
      MastodonStub.install(fn _request -> {429, %{"error" => "Too many requests"}} end)

      {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(minutes_ago(10))})
      queued = state.catch_up
      {[], state} = Mastodon.tick(state)

      assert state.catch_up == queued
      assert state.wait_until_mono > System.monotonic_time(:millisecond)
    end

    test "a refused token stops the catch-up, and says so once" do
      MastodonStub.install(fn _request -> {401, %{"error" => "The access token is invalid"}} end)

      log =
        capture_log(fn ->
          {_frames, state} = Mastodon.on_open(%{init() | cursor: id_at(minutes_ago(10))})
          {[], state} = Mastodon.tick(state)
          assert state.catch_up == nil

          {_frames, state} = Mastodon.on_open(state)
          {[], _state} = Mastodon.tick(state)
        end)

      assert log =~ "MASTODON_ACCESS_TOKEN"
      assert length(String.split(log, "catch-up refused")) == 2
      refute log =~ @token
    end
  end

  describe "the cursor file" do
    test "is saved privately and read back", %{tmp_dir: dir} do
      path = Path.join(dir, "mastodon.cursor")
      state = %{init() | cursor: "113456789012345678"}

      {[], _state} = Mastodon.tick(state)

      assert File.stat!(path).mode |> band(0o777) == 0o600
      assert init().cursor == "113456789012345678"
      refute File.read!(path) =~ @token
    end

    test "is saved on disconnect too", %{tmp_dir: dir} do
      state = %{
        init()
        | cursor: "113456789012345678",
          last_save_mono: System.monotonic_time(:millisecond)
      }

      Mastodon.on_disconnect(state)

      assert CursorFile.read(Path.join(dir, "mastodon.cursor")) =~ "113456789012345678"
    end

    test "a position from another server is not used", %{tmp_dir: dir} do
      CursorFile.write(
        Path.join(dir, "mastodon.cursor"),
        Jason.encode!(%{version: 1, instance: "other.example", last: "113456789012345678"})
      )

      assert init().cursor == nil
    end

    test "a damaged file is ignored", %{tmp_dir: dir} do
      CursorFile.write(Path.join(dir, "mastodon.cursor"), "{not json")

      assert init().cursor == nil
    end
  end

  describe "end to end" do
    setup %{tmp_dir: dir} do
      Monitor.reset()
      server = FakeWsServer.start()
      test = self()

      # The worker makes these requests, so a handler in this process's
      # dictionary cannot answer them; this one reports each to the test.
      MastodonStub.install_global(fn request ->
        send(test, {:worker_request, request.url.path, request.options[:params]})
        {200, []}
      end)

      on_exit(&MastodonStub.uninstall_global/0)

      Application.put_env(:smm_monitor, Mastodon,
        instance: @instance,
        streaming_url: server.url,
        cursor_file: Path.join(dir, "mastodon.cursor"),
        req_options: MastodonStub.req_options()
      )

      set_clients(["Acme"])
      :ok
    end

    test "subscribes, stores matching posts and catches up after a drop" do
      [local | _rest] = fixture()

      log =
        capture_log(fn ->
          start_worker()
          assert_receive {:fake_ws_connected, conn, request}, 2_000
          assert request.path == "/api/v1/streaming"
          assert request.headers["authorization"] == "Bearer " <> @token

          assert_receive {:fake_ws_frame, ^conn, 1, subscribe}, 1_000
          assert Jason.decode!(subscribe) == %{"type" => "subscribe", "stream" => "public"}

          matching = %{local | "id" => id_at(minutes_ago(1))}
          other = %{local | "id" => id_at(minutes_ago(0)), "content" => "<p>Nothing here</p>"}

          FakeWsServer.send_text(conn, Jason.encode!(update(matching)))
          FakeWsServer.send_text(conn, Jason.encode!(update(other)))

          assert eventually(fn -> Monitor.recent(:all, 100, "acme") != [] end)

          assert [%{platform: :mastodon, author: "@maya@mastodon.example"}] =
                   Monitor.recent(:all, 100, "acme")

          # The connection drops; the stream comes back and asks for the gap.
          FakeWsServer.drop(conn)
          assert_receive {:fake_ws_connected, _conn, _request}, 4_000
          assert_receive {:worker_request, "/api/v1/timelines/public", params}, 7_000
          assert params[:min_id] == other["id"]

          status = StreamWorker.status(:mastodon)
          refute inspect(status, limit: :infinity) =~ @token

          refute inspect(:sys.get_status(StreamWorker.name(:mastodon)), limit: :infinity) =~
                   @token
        end)

      refute log =~ @token
    end

    test "a refused token stops the stream with a message that says what to fix" do
      server = FakeWsServer.start(response: {:status, 401})
      settings(streaming_url: server.url)

      capture_log(fn ->
        start_worker()
        assert eventually(fn -> StreamWorker.status(:mastodon).connection == :stopped end)
      end)

      assert StreamWorker.status(:mastodon).last_error =~ "MASTODON_ACCESS_TOKEN"
      # One attempt, refused, and no more.
      assert_received {:fake_ws_connected, _conn, _request}
      refute_receive {:fake_ws_connected, _conn, _request}, 2_500
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp init, do: Mastodon.init_state(%{credentials: [access_token: @token]})

  defp settings(changes) do
    current = Application.get_env(:smm_monitor, Mastodon, [])
    Application.put_env(:smm_monitor, Mastodon, Keyword.merge(current, changes))
  end

  defp fixture, do: "test/fixtures/mastodon_timeline.json" |> File.read!() |> Jason.decode!()

  defp update(status),
    do: %{"stream" => ["public"], "event" => "update", "payload" => Jason.encode!(status)}

  # A Mastodon id made at `ms` (Unix milliseconds).
  defp id_at(ms), do: Integer.to_string(ms <<< 16 ||| :rand.uniform(0xFFFF))

  defp minutes_ago(minutes), do: System.os_time(:millisecond) - minutes * 60_000

  # A full page of public posts made just after `after_ms`.
  defp full_page(after_ms) do
    [local | _rest] = fixture()

    for n <- 40..1//-1 do
      %{local | "id" => Integer.to_string((after_ms + n) <<< 16)}
    end
  end

  # Runs `fun` with its log captured, for answers that are logged.
  defp capture(fun), do: fun |> with_log() |> elem(0)

  defp start_worker do
    start_supervised!({StreamWorker, module: Mastodon})
    StreamWorker.poll_now(:mastodon)
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
