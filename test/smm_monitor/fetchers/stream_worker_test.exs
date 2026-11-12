defmodule SmmMonitor.Fetchers.StreamWorkerTest do
  @moduledoc """
  The stream worker end to end, against a WebSocket server on 127.0.0.1.

  Nothing leaves the machine: `TestStream` points the worker at
  `SmmMonitor.FakeWsServer`, and the server is driven from the test.
  """

  use SmmMonitor.ClientCase, async: false

  import ExUnit.CaptureLog

  alias SmmMonitor.{FakeWsServer, Monitor}
  alias SmmMonitor.Fetchers.StreamWorker

  defmodule TestStream do
    @moduledoc false
    use SmmMonitor.Fetchers.Stream, platform: :stream_test, display_name: "Stream test"

    defmodule State do
      @moduledoc false
      defstruct token: "super-secret-token",
                opened: 0,
                closed: 0,
                beat_ms: nil,
                zombie: false,
                resumable: false,
                pending: []
    end

    @impl true
    def ready?(%{opts: opts}), do: Keyword.get(opts, :ready, true)

    @impl true
    def init_state(_context), do: %State{}

    @impl true
    def url(%{opts: opts}, _state), do: {:ok, Keyword.fetch!(opts, :url)}

    @impl true
    def on_open(state), do: {[~s({"op":"hello"})], %{state | opened: state.opened + 1}}

    @impl true
    def on_disconnect(state), do: %{state | closed: state.closed + 1}

    @impl true
    def handle_message(%{"stop" => reason}, state), do: {:stop, reason, state}
    def handle_message(%{"reconnect" => true}, state), do: {:reconnect, state}

    # Like Discord's Hello: the heartbeat interval only arrives in a message.
    def handle_message(%{"beat_ms" => ms}, state), do: {:ok, [], [], %{state | beat_ms: ms}}
    def handle_message(%{"zombie" => true}, state), do: {:ok, [], [], %{state | zombie: true}}

    def handle_message(%{"resumable" => true}, state),
      do: {:ok, [], [], %{state | resumable: true}}

    # A post held back for tick/1, as a catch-up fetch would deliver it.
    def handle_message(%{"later" => id, "text" => text}, state),
      do: {:ok, [], [], %{state | pending: [post(id, text) | state.pending]}}

    def handle_message(%{"id" => id, "text" => text}, state),
      do: {:ok, [post(id, text)], [], state}

    def handle_message(_other, state), do: {:ok, [], [], state}

    @impl true
    def heartbeat_ms(state), do: state.beat_ms

    @impl true
    def heartbeat(%State{zombie: true} = state), do: {:reconnect, state}
    def heartbeat(state), do: {[~s({"op":"beat"})], state}

    @impl true
    def handle_close(4004, state), do: {:stop, "bad token", state}
    def handle_close(_code, state), do: {:reconnect, state}

    @impl true
    def close_code(%State{resumable: true}), do: 4000
    def close_code(_state), do: 1000

    @impl true
    def max_message_bytes,
      do: Application.get_env(:smm_monitor, :stream_test_max_bytes, 1_048_576)

    @impl true
    def tick(state), do: {state.pending, %{state | pending: []}}

    defp post(id, text) do
      %{
        id: id,
        author: "someone",
        text: text,
        url: "https://example.test/#{id}",
        timestamp: DateTime.utc_now()
      }
    end

    # Proves enrich runs on the batch before it is stored.
    @impl true
    def enrich(posts, state), do: {Enum.map(posts, &%{&1 | author: "@enriched"}), state}
  end

  setup do
    Monitor.reset()

    mocks = Application.get_env(:smm_monitor, :mock_platforms)
    Application.put_env(:smm_monitor, :mock_platforms, stream_test: false)

    on_exit(fn ->
      if mocks,
        do: Application.put_env(:smm_monitor, :mock_platforms, mocks),
        else: Application.delete_env(:smm_monitor, :mock_platforms)
    end)

    set_clients(["Acme"])
    :ok
  end

  describe "a live connection" do
    test "connects, sends its opening frames, and stores only matched posts" do
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/stream")

      conn = FakeWsServer.await_connection()
      assert_receive {:fake_ws_frame, ^conn, 1, ~s({"op":"hello"})}

      FakeWsServer.send_text(conn, ~s({"id":"1","text":"I love Acme"}))
      FakeWsServer.send_text(conn, ~s({"id":"2","text":"nothing to see"}))
      FakeWsServer.send_text(conn, "not json at all")

      assert eventually(fn -> Monitor.recent(:all, 100, "acme") != [] end)

      assert [mention] = Monitor.recent(:all, 100, "acme")
      assert mention.id == "1"
      assert mention.platform == :stream_test
      assert mention.author == "@enriched"

      status = StreamWorker.status(:stream_test)
      assert status.mode == :live
      assert status.transport == :stream
      assert status.connection == :connected
      assert status.connected?
      assert status.events_seen == 3
      assert status.matched == 1
      assert status.inserted == 1
      assert status.next_poll_at == nil
      assert %DateTime{} = status.last_success_at
    end

    test "a post that names two clients is stored for both" do
      set_clients(["Acme", "Beta"])
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()

      FakeWsServer.send_text(conn, ~s({"id":"9","text":"Acme vs Beta"}))

      assert eventually(fn ->
               Monitor.recent(:all, 100, "acme") != [] and Monitor.recent(:all, 100, "beta") != []
             end)
    end

    test "a client added while connected is matched without reconnecting" do
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()

      set_clients(["Acme", "Gamma"])
      StreamWorker.poll_now(:stream_test)
      FakeWsServer.send_text(conn, ~s({"id":"g1","text":"gamma rays"}))

      assert eventually(fn -> Monitor.recent(:all, 100, "gamma") != [] end)
      assert StreamWorker.status(:stream_test).poll_count == 1
      refute_received {:fake_ws_connected, _conn, _request}
    end
  end

  describe "losing the connection" do
    test "a server close is recorded and followed by a reconnect" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()

        FakeWsServer.close(conn, 1011)

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).connection == :reconnecting
               end)

        assert StreamWorker.status(:stream_test).last_error == {:closed_by_server, 1011}

        # Back-off on the first failure is 1-2 seconds.
        FakeWsServer.await_connection(4_000)
        assert eventually(fn -> StreamWorker.status(:stream_test).connected? end)
        assert StreamWorker.status(:stream_test).poll_count == 2
      end)

      # The module saw the disconnect, so it could save its position.
      assert %{closed: 1, opened: 2} = platform_state()
    end

    test "a dropped TCP connection reconnects too" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()
        FakeWsServer.drop(conn)

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).last_error == :closed_by_server
               end)

        FakeWsServer.await_connection(4_000)
      end)
    end

    test "a frame over the size cap is refused and the connection replaced" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()

        # Only a header promising 2 MB: the worker must not wait for, or
        # allocate, the rest.
        FakeWsServer.send_raw(conn, <<0x81, 127, 2_000_000::64>>)

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).last_error == :message_too_large
               end)

        assert_receive {:fake_ws_closed, ^conn}, 1_000
        FakeWsServer.await_connection(4_000)
      end)

      assert StreamWorker.status(:stream_test).failures >= 1
    end

    test "a platform asking to reconnect gets a fresh connection" do
      server = FakeWsServer.start()

      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()
      FakeWsServer.send_text(conn, ~s({"reconnect":true}))

      assert_receive {:fake_ws_closed, ^conn}, 1_000
      FakeWsServer.await_connection(4_000)
      # An expected reconnect is not shown as an error.
      assert StreamWorker.status(:stream_test).last_error == nil
    end

    test "a platform that says stop is not retried straight away" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()
        FakeWsServer.send_text(conn, ~s({"stop":"token revoked"}))

        assert eventually(fn -> StreamWorker.status(:stream_test).connection == :stopped end)
      end)

      assert StreamWorker.status(:stream_test).last_error == "token revoked"
      refute_receive {:fake_ws_connected, _conn, _request}, 2_500
    end

    test "a server that refuses the upgrade counts as a failure" do
      server = FakeWsServer.start(response: {:status, 429})

      capture_log(fn ->
        start_worker(url: server.url <> "/")

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).last_error == {:upgrade_refused, "429"}
               end)
      end)

      assert StreamWorker.status(:stream_test).connection == :reconnecting
    end
  end

  describe "hooks a platform can use" do
    test "a heartbeat interval learned from a message starts the heartbeat" do
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()
      assert_receive {:fake_ws_frame, ^conn, 1, ~s({"op":"hello"})}

      refute_receive {:fake_ws_frame, ^conn, 1, ~s({"op":"beat"})}, 200

      FakeWsServer.send_text(conn, ~s({"beat_ms":50}))
      assert_receive {:fake_ws_frame, ^conn, 1, ~s({"op":"beat"})}, 1_000
      # And it keeps going.
      assert_receive {:fake_ws_frame, ^conn, 1, ~s({"op":"beat"})}, 1_000
    end

    test "a heartbeat that asks to reconnect replaces the connection" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()
        FakeWsServer.send_text(conn, ~s({"zombie":true}))
        FakeWsServer.send_text(conn, ~s({"beat_ms":50}))

        assert_receive {:fake_ws_closed, ^conn}, 1_000

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).last_error == :heartbeat_not_acknowledged
               end)

        FakeWsServer.await_connection(4_000)
      end)
    end

    test "a close code the platform treats as fatal stops the worker" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()
        FakeWsServer.close(conn, 4004)

        assert eventually(fn -> StreamWorker.status(:stream_test).connection == :stopped end)
      end)

      assert StreamWorker.status(:stream_test).last_error == "bad token"
      refute_receive {:fake_ws_connected, _conn, _request}, 2_500
    end

    test "the platform chooses the close code" do
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()

      FakeWsServer.send_text(conn, ~s({"resumable":true}))
      FakeWsServer.send_text(conn, ~s({"reconnect":true}))

      assert_receive {:fake_ws_frame, ^conn, 8, <<4000::16>>}, 1_000
      FakeWsServer.await_connection(4_000)
    end

    test "the platform sets its own message size cap" do
      Application.put_env(:smm_monitor, :stream_test_max_bytes, 100)
      on_exit(fn -> Application.delete_env(:smm_monitor, :stream_test_max_bytes) end)
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/")
        conn = FakeWsServer.await_connection()
        FakeWsServer.send_text(conn, String.duplicate("x", 200))

        assert eventually(fn ->
                 StreamWorker.status(:stream_test).last_error == :message_too_large
               end)
      end)
    end

    test "posts returned by tick are matched and stored" do
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")
      conn = FakeWsServer.await_connection()

      FakeWsServer.send_text(conn, ~s({"later":"t1","text":"Acme, a while ago"}))
      FakeWsServer.send_text(conn, ~s({"later":"t2","text":"unrelated"}))
      assert eventually(fn -> length(platform_state().pending) == 2 end)

      StreamWorker.poll_now(:stream_test)

      assert eventually(fn -> Monitor.recent(:all, 100, "acme") != [] end)
      assert [%{id: "t1", author: "@enriched"}] = Monitor.recent(:all, 100, "acme")
      assert platform_state().pending == []
    end
  end

  describe "not connecting" do
    test "when the platform is not configured" do
      server = FakeWsServer.start()

      capture_log(fn ->
        start_worker(url: server.url <> "/", ready: false)
        assert eventually(fn -> StreamWorker.status(:stream_test).mode == :unconfigured end)
      end)

      assert StreamWorker.status(:stream_test).connection == :idle
      refute_received {:fake_ws_connected, _conn, _request}
    end

    test "when there is no client to match for" do
      set_clients([])
      server = FakeWsServer.start()
      start_worker(url: server.url <> "/")

      assert eventually(fn -> StreamWorker.status(:stream_test).mode == :live end)
      assert StreamWorker.status(:stream_test).connection == :idle
      refute_receive {:fake_ws_connected, _conn, _request}, 200
    end

    test "status is :unavailable when the worker is not running" do
      assert StreamWorker.status(:stream_test) == :unavailable
    end
  end

  test "format_status keeps the platform's state out of crash reports" do
    server = FakeWsServer.start()
    start_worker(url: server.url <> "/")
    FakeWsServer.await_connection()

    status = :sys.get_status(StreamWorker.name(:stream_test))
    refute inspect(status, limit: :infinity) =~ "super-secret-token"
    assert inspect(status, limit: :infinity) =~ "redacted"
  end

  # --- helpers ----------------------------------------------------------------

  defp start_worker(opts) do
    start_supervised!({StreamWorker, module: TestStream, opts: opts})
    # Skip the start-up jitter.
    StreamWorker.poll_now(:stream_test)
  end

  defp platform_state do
    :sys.get_state(StreamWorker.name(:stream_test)).platform_state
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
