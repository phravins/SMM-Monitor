defmodule SmmMonitor.WebSocketTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.{FakeWsServer, WebSocket}

  doctest SmmMonitor.WebSocket

  # A struct with no socket, for decoding tests that never reply.
  defp ws(max \\ 1_048_576), do: %WebSocket{transport: :gen_tcp, max_message_bytes: max}

  describe "decode_frame/2" do
    test "reads 16-bit and 64-bit lengths" do
      medium = String.duplicate("a", 300)
      large = String.duplicate("b", 70_000)

      assert {:ok, {true, 1, ^medium}, ""} =
               WebSocket.decode_frame(FakeWsServer.frame(1, medium), 1_000_000)

      assert {:ok, {true, 2, ^large}, ""} =
               WebSocket.decode_frame(FakeWsServer.frame(2, large), 1_000_000)
    end

    test "waits for more bytes rather than guessing" do
      frame = FakeWsServer.frame(1, String.duplicate("x", 300))

      for cut <- [0, 1, 2, 3, 100] do
        assert WebSocket.decode_frame(binary_part(frame, 0, cut), 1_000) == :more
      end
    end

    test "refuses a frame over the limit from its header alone" do
      # Only the header has arrived; the size is enough to refuse it.
      assert WebSocket.decode_frame(<<0x82, 127, 5_000_000_000::64>>, 1_048_576) ==
               {:error, :message_too_large}
    end

    test "unmasks a masked frame" do
      # What encode_frame/2 produces is masked; decoding it gives the text back.
      assert {:ok, {true, 1, "hello"}, ""} =
               WebSocket.decode_frame(WebSocket.encode_frame(1, "hello"), 100)
    end
  end

  describe "encode_frame/2" do
    test "round-trips every length encoding, always masked" do
      for size <- [0, 1, 125, 126, 65_535, 65_536] do
        payload = :crypto.strong_rand_bytes(size)
        frame = WebSocket.encode_frame(2, payload)

        <<_fin_op, mask_bit::1, _len::7, _rest::binary>> = frame
        assert mask_bit == 1, "client frames must be masked (size #{size})"
        assert {:ok, {true, 2, ^payload}, ""} = WebSocket.decode_frame(frame, 1_000_000)
      end
    end
  end

  describe "handle_data/2" do
    test "returns every complete message in a chunk, in order" do
      data = FakeWsServer.frame(1, "one") <> FakeWsServer.frame(1, "two")

      assert {:ok, %WebSocket{buffer: ""}, [text: "one", text: "two"]} =
               WebSocket.handle_data(ws(), data)
    end

    test "keeps a partial frame until the rest arrives, a byte at a time" do
      data = FakeWsServer.frame(1, ~s({"kind":"commit"}))

      {ws, messages} =
        data
        |> :binary.bin_to_list()
        |> Enum.reduce({ws(), []}, fn byte, {ws, acc} ->
          {:ok, ws, messages} = WebSocket.handle_data(ws, <<byte>>)
          {ws, acc ++ messages}
        end)

      assert messages == [text: ~s({"kind":"commit"})]
      assert ws.buffer == ""
    end

    test "reassembles fragments, delivering a control frame in between at once" do
      data =
        FakeWsServer.frame(1, "hel", false) <>
          FakeWsServer.frame(10, "pong-payload") <>
          FakeWsServer.frame(0, "lo ", false) <> FakeWsServer.frame(0, "world")

      assert {:ok, ws, [pong: "pong-payload", text: "hello world"]} =
               WebSocket.handle_data(ws(), data)

      assert ws.fragment == nil
    end

    test "refuses a message that grows past the limit across fragments" do
      data = FakeWsServer.frame(1, "12345", false) <> FakeWsServer.frame(0, "67890")

      assert {:error, :message_too_large, _ws} = WebSocket.handle_data(ws(8), data)
    end

    test "refuses a continuation with nothing to continue" do
      assert {:error, :unexpected_continuation, _ws} =
               WebSocket.handle_data(ws(), FakeWsServer.frame(0, "orphan"))
    end

    test "refuses a new message in the middle of a fragmented one" do
      data = FakeWsServer.frame(1, "a", false) <> FakeWsServer.frame(1, "b")
      assert {:error, :interleaved_message, _ws} = WebSocket.handle_data(ws(), data)
    end

    test "refuses unknown opcodes" do
      assert {:error, {:unknown_opcode, 3}, _ws} =
               WebSocket.handle_data(ws(), FakeWsServer.frame(3, ""))
    end

    test "reads the close code and reason" do
      assert {:ok, _ws, [{:close, 4004, "bad token"}]} =
               WebSocket.handle_data(ws(), FakeWsServer.frame(8, <<4004::16, "bad token">>))

      assert {:ok, _ws, [{:close, nil, ""}]} =
               WebSocket.handle_data(ws(), FakeWsServer.frame(8, ""))
    end
  end

  describe "parse_url/1" do
    test "allows plain ws:// only to loopback" do
      assert {:ok, _uri} = WebSocket.parse_url("ws://localhost:4000/x")
      assert {:ok, _uri} = WebSocket.parse_url("ws://127.0.0.1:4000/x")
      assert WebSocket.parse_url("ws://10.0.0.1/x") == {:error, :insecure_url}
    end

    test "refuses anything without a host" do
      assert WebSocket.parse_url("wss://") == {:error, :invalid_url}
      assert WebSocket.parse_url("wss:/path") == {:error, :invalid_url}
      assert WebSocket.parse_url(nil) == {:error, :invalid_url}
    end
  end

  describe "connect/2 against a local server" do
    test "performs the handshake with the path, query and extra headers" do
      server = FakeWsServer.start()

      assert {:ok, ws} =
               WebSocket.connect(server.url <> "/subscribe?wantedCollections=a.b",
                 headers: [{"User-Agent", "smm-monitor-test"}]
               )

      assert_receive {:fake_ws_connected, _conn, request}
      assert request.path == "/subscribe?wantedCollections=a.b"
      assert request.headers["user-agent"] == "smm-monitor-test"
      assert request.headers["sec-websocket-version"] == "13"
      assert request.headers["host"] == "127.0.0.1:#{server.port}"

      WebSocket.close(ws)
    end

    test "keeps bytes that arrived with the handshake response" do
      server = FakeWsServer.start(after_handshake: FakeWsServer.frame(1, "early"))

      {:ok, ws} = WebSocket.connect(server.url <> "/")

      # They may or may not share the packet; either way nothing is lost.
      data = if ws.buffer == "", do: recv(ws), else: ""
      assert {:ok, _ws, [text: "early"]} = WebSocket.handle_data(ws, data)
      WebSocket.close(ws)
    end

    test "refuses a server that answers with the wrong accept key" do
      server = FakeWsServer.start(response: :bad_accept)
      assert WebSocket.connect(server.url <> "/") == {:error, :bad_accept_key}
    end

    test "refuses a server that does not upgrade" do
      server = FakeWsServer.start(response: {:status, 403})
      assert WebSocket.connect(server.url <> "/") == {:error, {:upgrade_refused, "403"}}
    end

    test "reports a closed port as a connect failure" do
      server = FakeWsServer.start()
      Process.unlink(server.pid)
      Process.exit(server.pid, :kill)
      Process.sleep(20)

      assert {:error, {:connect_failed, _reason}} = WebSocket.connect(server.url <> "/")
    end

    test "sends masked text, answers pings with pongs, and closes with a code" do
      server = FakeWsServer.start()
      {:ok, ws} = WebSocket.connect(server.url <> "/")
      conn = FakeWsServer.await_connection()

      :ok = WebSocket.send_text(ws, ~s({"op":1}))
      assert_receive {:fake_ws_frame, ^conn, 1, ~s({"op":1})}

      FakeWsServer.send_raw(conn, FakeWsServer.frame(9, "are you there"))
      assert {:ok, _ws, [ping: "are you there"]} = WebSocket.handle_data(ws, recv(ws))
      assert_receive {:fake_ws_frame, ^conn, 10, "are you there"}

      :ok = WebSocket.close(ws, 4000)
      assert_receive {:fake_ws_frame, ^conn, 8, <<4000::16>>}
    end
  end

  defp recv(%WebSocket{transport: :gen_tcp, socket: socket}) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    data
  end
end
