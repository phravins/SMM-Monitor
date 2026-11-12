defmodule SmmMonitor.FakeWsServer do
  @moduledoc """
  A tiny WebSocket server on 127.0.0.1 for tests.

  It speaks just enough RFC 6455 to test `SmmMonitor.WebSocket` and
  `SmmMonitor.Fetchers.StreamWorker` against a real socket without
  touching the network:

      server = FakeWsServer.start()
      {:ok, ws} = WebSocket.connect(server.url <> "/subscribe")
      conn = FakeWsServer.await_connection()
      FakeWsServer.send_text(conn, ~s({"hello":1}))

  Every accepted connection is reported to the process that started the
  server as `{:fake_ws_connected, conn, request}`, where `request` has the
  request `:path` and lowercased `:headers`. Frames the client sends
  arrive as `{:fake_ws_frame, conn, opcode, payload}`, and a client that
  hangs up as `{:fake_ws_closed, conn}`.

  Options:

    * `:response` - `:ok` (default), `:bad_accept` or `{:status, code}`
    * `:after_handshake` - bytes to send in the same packet as the 101
      response, to test that they are not lost
  """

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @doc "Starts a server linked to the caller. Returns `%{port, url, pid}`."
  def start(opts \\ []) do
    owner = self()
    reply = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        send(owner, {reply, port})
        accept_loop(listen, owner, opts)
      end)

    receive do
      {^reply, port} -> %{port: port, url: "ws://127.0.0.1:#{port}", pid: pid}
    after
      1_000 -> raise "fake WebSocket server did not start"
    end
  end

  @doc "Waits for the next connection and returns it."
  def await_connection(timeout \\ 2_000) do
    receive do
      {:fake_ws_connected, conn, _request} -> conn
    after
      timeout -> raise "no WebSocket connection within #{timeout}ms"
    end
  end

  @doc "Sends a text message to the client."
  def send_text(conn, text), do: send_raw(conn, frame(1, text))

  @doc "Sends raw bytes to the client, for malformed or partial frames."
  def send_raw(conn, bytes), do: send(conn, {:send, bytes})

  @doc "Sends a close frame with a code, then drops the connection."
  def close(conn, code \\ 1000) do
    send_raw(conn, frame(8, <<code::16>>))
    drop(conn)
  end

  @doc "Drops the TCP connection without a close frame."
  def drop(conn), do: send(conn, :drop)

  @doc "An unmasked server frame, as a server would send it."
  def frame(opcode, payload, fin \\ true) do
    payload = IO.iodata_to_binary(payload)

    length =
      case byte_size(payload) do
        size when size < 126 -> <<0::1, size::7>>
        size when size < 65_536 -> <<0::1, 126::7, size::16>>
        size -> <<0::1, 127::7, size::64>>
      end

    <<if(fin, do: 1, else: 0)::1, 0::3, opcode::4, length::binary, payload::binary>>
  end

  # --- server side ----------------------------------------------------------

  defp accept_loop(listen, owner, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn_link(fn -> handshake(owner, opts) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        accept_loop(listen, owner, opts)

      {:error, _reason} ->
        :ok
    end
  end

  defp handshake(owner, opts) do
    socket =
      receive do
        {:socket, socket} -> socket
      end

    {:ok, head} = read_head(socket, "")
    [request_line | header_lines] = String.split(head, "\r\n")
    [_method, path, _version] = String.split(request_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    accept = :crypto.hash(:sha, headers["sec-websocket-key"] <> @guid) |> Base.encode64()

    response =
      case Keyword.get(opts, :response, :ok) do
        :ok -> upgrade(accept)
        :bad_accept -> upgrade(Base.encode64("not the right value!"))
        {:status, code} -> "HTTP/1.1 #{code} Nope\r\nContent-Length: 0\r\n\r\n"
      end

    :ok = :gen_tcp.send(socket, [response, Keyword.get(opts, :after_handshake, "")])
    send(owner, {:fake_ws_connected, self(), %{path: path, headers: headers}})
    :ok = :inet.setopts(socket, active: true)
    serve(socket, owner, "")
  end

  defp upgrade(accept) do
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" <>
      "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _rest] ->
        {:ok, head}

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        read_head(socket, acc <> data)
    end
  end

  defp serve(socket, owner, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        serve(socket, owner, decode(buffer <> data, owner))

      {:tcp_closed, ^socket} ->
        send(owner, {:fake_ws_closed, self()})

      {:send, bytes} ->
        _ = :gen_tcp.send(socket, bytes)
        serve(socket, owner, buffer)

      :drop ->
        :gen_tcp.close(socket)
    end
  end

  defp decode(buffer, owner) do
    case SmmMonitor.WebSocket.decode_frame(buffer, 64 * 1024 * 1024) do
      {:ok, {_fin, opcode, payload}, rest} ->
        send(owner, {:fake_ws_frame, self(), opcode, payload})
        decode(rest, owner)

      :more ->
        buffer
    end
  end
end
