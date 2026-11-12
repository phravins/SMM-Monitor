defmodule SmmMonitor.WebSocket do
  @moduledoc """
  A small WebSocket client (RFC 6455) on top of `:ssl` and `:gen_tcp`.

  The streaming platforms (Bluesky's Jetstream, Discord's Gateway,
  Mastodon's streaming API) each need one long-lived WebSocket. This module
  is the whole client: it opens the connection, does the HTTP upgrade
  handshake, and turns bytes into messages and messages into bytes. It
  holds no process of its own; the caller (`SmmMonitor.Fetchers.StreamWorker`)
  owns the socket, receives `{:ssl, socket, data}` messages for it and
  hands each one to `handle_data/2`.

  It exists instead of a Hex dependency so the release carries no extra
  native or protocol code beyond what Erlang/OTP already ships, and so the
  security-relevant parts are short enough to read:

    * `wss://` connections verify the server's certificate against the
      operating system's trusted CAs and check the hostname. There is no
      option to turn that off.
    * Plain `ws://` is accepted only for `localhost` and loopback
      addresses, which is what the test suite uses.
    * A message larger than `:max_message_bytes` (1 MB by default) closes
      the connection instead of growing a buffer without limit. A stranger
      on a public firehose cannot make the app allocate whatever they like.
    * The handshake response is capped at 16 KB and must carry the
      `Sec-WebSocket-Accept` value derived from our random key.
  """

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @max_handshake_bytes 16_384
  @default_max_message_bytes 1_048_576
  @connect_timeout_ms 10_000

  @opcodes %{0 => :continuation, 1 => :text, 2 => :binary, 8 => :close, 9 => :ping, 10 => :pong}

  defstruct [
    :transport,
    :socket,
    :host,
    buffer: "",
    # The opcode and payload chunks of a message arriving in fragments.
    fragment: nil,
    max_message_bytes: @default_max_message_bytes
  ]

  @type t :: %__MODULE__{}

  @typedoc "A complete message received from the server."
  @type message ::
          {:text, binary()}
          | {:binary, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, non_neg_integer() | nil, binary()}

  @doc """
  Connects and performs the upgrade handshake.

  Blocks for up to 10 seconds. The returned socket is in passive mode;
  call `activate/1` from the process that will own it.

  Options:

    * `:headers` - extra request headers, as `[{name, value}]`
    * `:max_message_bytes` - the largest message accepted
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) do
    with {:ok, uri} <- parse_url(url),
         {:ok, transport, socket} <- open(uri),
         {:ok, leftover} <- handshake(transport, socket, uri, Keyword.get(opts, :headers, [])) do
      {:ok,
       %__MODULE__{
         transport: transport,
         socket: socket,
         host: uri.host,
         buffer: leftover,
         max_message_bytes: Keyword.get(opts, :max_message_bytes, @default_max_message_bytes)
       }}
    end
  end

  @doc """
  Checks a URL is one `connect/2` will accept: `wss://` with a host, or
  `ws://` to a loopback address.

      iex> {:ok, uri} = SmmMonitor.WebSocket.parse_url("wss://jetstream.example/subscribe?x=1")
      iex> uri.host
      "jetstream.example"
      iex> SmmMonitor.WebSocket.parse_url("ws://example.com/")
      {:error, :insecure_url}
      iex> SmmMonitor.WebSocket.parse_url("https://example.com/")
      {:error, :invalid_url}
  """
  @spec parse_url(String.t()) :: {:ok, URI.t()} | {:error, :invalid_url | :insecure_url}
  def parse_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "wss", host: host} = uri} when is_binary(host) and host != "" ->
        {:ok, %{uri | port: uri.port || 443}}

      {:ok, %URI{scheme: "ws", host: host} = uri} when is_binary(host) and host != "" ->
        if loopback?(host), do: {:ok, %{uri | port: uri.port || 80}}, else: {:error, :insecure_url}

      _other ->
        {:error, :invalid_url}
    end
  end

  def parse_url(_url), do: {:error, :invalid_url}

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  @doc "Hands the socket to `pid`, which will then receive its messages."
  @spec controlling_process(t(), pid()) :: :ok | {:error, term()}
  def controlling_process(%__MODULE__{transport: :ssl, socket: socket}, pid),
    do: :ssl.controlling_process(socket, pid)

  def controlling_process(%__MODULE__{transport: :gen_tcp, socket: socket}, pid),
    do: :gen_tcp.controlling_process(socket, pid)

  @doc """
  Asks for the next chunk of data as a message to the owning process.

  `active: :once` rather than `true`, so a server sending faster than
  the app can process fills the operating system's buffer and slows the
  sender down, instead of filling the process mailbox.
  """
  @spec activate(t()) :: :ok | {:error, term()}
  def activate(%__MODULE__{transport: :ssl, socket: socket}),
    do: :ssl.setopts(socket, active: :once)

  def activate(%__MODULE__{transport: :gen_tcp, socket: socket}),
    do: :inet.setopts(socket, active: :once)

  @doc """
  Feeds received bytes in and returns the complete messages they finish.

  Pings are answered here, so callers never have to. A close from the
  server is answered too and returned, so the caller knows to stop.
  """
  @spec handle_data(t(), binary()) :: {:ok, t(), [message()]} | {:error, term(), t()}
  def handle_data(%__MODULE__{} = ws, data) do
    decode_all(%{ws | buffer: ws.buffer <> data}, [])
  end

  defp decode_all(ws, acc) do
    case decode_frame(ws.buffer, ws.max_message_bytes) do
      :more ->
        {:ok, ws, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason, ws}

      {:ok, frame, rest} ->
        case assemble(%{ws | buffer: rest}, frame) do
          {:ok, ws, nil} -> decode_all(ws, acc)
          {:ok, ws, message} -> decode_all(ws, [message | acc]) |> answer(message)
          {:error, reason, ws} -> {:error, reason, ws}
        end
    end
  end

  # Replies that the protocol requires. Done after decoding so the reply
  # goes out on the socket in the order the requests came in.
  defp answer({:ok, ws, _messages} = result, {:ping, payload}) do
    _ = send_frame(ws, 10, payload)
    result
  end

  defp answer(result, _message), do: result

  # Control frames can arrive between the fragments of a data message, and
  # are delivered at once. Data fragments are stitched into one message.
  defp assemble(ws, {fin, opcode, payload}) do
    case {Map.get(@opcodes, opcode), ws.fragment} do
      {nil, _fragment} ->
        {:error, {:unknown_opcode, opcode}, ws}

      {:close, _fragment} ->
        {:ok, ws, close_message(payload)}

      {control, _fragment} when control in [:ping, :pong] ->
        {:ok, ws, {control, payload}}

      {:continuation, nil} ->
        {:error, :unexpected_continuation, ws}

      {:continuation, {type, chunks, size}} ->
        add_fragment(ws, fin, type, [payload | chunks], size + byte_size(payload))

      {type, nil} ->
        add_fragment(ws, fin, type, [payload], byte_size(payload))

      {_type, _fragment} ->
        {:error, :interleaved_message, ws}
    end
  end

  defp add_fragment(ws, _fin, _type, _chunks, size) when size > ws.max_message_bytes,
    do: {:error, :message_too_large, ws}

  defp add_fragment(ws, true, type, chunks, _size),
    do: {:ok, %{ws | fragment: nil}, {type, chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

  defp add_fragment(ws, false, type, chunks, size),
    do: {:ok, %{ws | fragment: {type, chunks, size}}, nil}

  defp close_message(<<code::16, reason::binary>>), do: {:close, code, reason}
  defp close_message(_payload), do: {:close, nil, ""}

  @doc """
  Decodes one frame from the front of `buffer`.

  Returns `:more` when the frame is not complete yet. Server frames are
  normally unmasked, but a masked one is unmasked rather than refused.

      iex> SmmMonitor.WebSocket.decode_frame(<<0x81, 2, "hi", "rest">>, 100)
      {:ok, {true, 1, "hi"}, "rest"}
      iex> SmmMonitor.WebSocket.decode_frame(<<0x81, 5, "hi">>, 100)
      :more
      iex> SmmMonitor.WebSocket.decode_frame(<<0x81, 126, 1000::16>>, 100)
      {:error, :message_too_large}
  """
  @spec decode_frame(binary(), pos_integer()) ::
          {:ok, {boolean(), non_neg_integer(), binary()}, binary()}
          | :more
          | {:error, term()}
  def decode_frame(<<fin::1, _rsv::3, opcode::4, masked::1, len::7, rest::binary>>, max) do
    with {:ok, length, rest} <- payload_length(len, rest),
         :ok <- check_size(length, max),
         {:ok, mask, rest} <- take_mask(masked, rest) do
      case rest do
        <<payload::binary-size(length), rest::binary>> ->
          {:ok, {fin == 1, opcode, unmask(payload, mask)}, rest}

        _incomplete ->
          :more
      end
    end
  end

  def decode_frame(_buffer, _max), do: :more

  defp payload_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp payload_length(_len, _rest), do: :more

  defp check_size(length, max) when length > max, do: {:error, :message_too_large}
  defp check_size(_length, _max), do: :ok

  defp take_mask(0, rest), do: {:ok, nil, rest}
  defp take_mask(1, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp take_mask(1, _rest), do: :more

  @doc """
  Encodes one client frame. Clients must mask every frame they send.

      iex> frame = SmmMonitor.WebSocket.encode_frame(1, "hi")
      iex> <<0x81, 0x82, _mask::binary-size(4), _payload::binary-size(2)>> = frame
      iex> byte_size(frame)
      8
  """
  @spec encode_frame(non_neg_integer(), iodata()) :: binary()
  def encode_frame(opcode, payload) do
    payload = IO.iodata_to_binary(payload)
    mask = :crypto.strong_rand_bytes(4)

    length =
      case byte_size(payload) do
        size when size < 126 -> <<1::1, size::7>>
        size when size < 65_536 -> <<1::1, 126::7, size::16>>
        size -> <<1::1, 127::7, size::64>>
      end

    <<1::1, 0::3, opcode::4, length::binary, mask::binary, unmask(payload, mask)::binary>>
  end

  # XOR with the repeating 4-byte key; the same operation masks and unmasks.
  defp unmask(payload, nil), do: payload

  defp unmask(<<>>, _mask), do: <<>>

  defp unmask(payload, mask) do
    size = byte_size(payload)
    key = mask |> :binary.copy(div(size, 4) + 1) |> binary_part(0, size)
    :crypto.exor(payload, key)
  end

  @doc "Sends a text message."
  @spec send_text(t(), iodata()) :: :ok | {:error, term()}
  def send_text(%__MODULE__{} = ws, text), do: send_frame(ws, 1, text)

  @doc "Sends a close frame and closes the socket."
  @spec close(t(), non_neg_integer()) :: :ok
  def close(%__MODULE__{} = ws, code \\ 1000) do
    _ = send_frame(ws, 8, <<code::16>>)
    _ = transport_close(ws)
    :ok
  end

  defp send_frame(%__MODULE__{transport: :ssl, socket: socket}, opcode, payload),
    do: :ssl.send(socket, encode_frame(opcode, payload))

  defp send_frame(%__MODULE__{transport: :gen_tcp, socket: socket}, opcode, payload),
    do: :gen_tcp.send(socket, encode_frame(opcode, payload))

  defp transport_close(%__MODULE__{transport: :ssl, socket: socket}), do: :ssl.close(socket)
  defp transport_close(%__MODULE__{transport: :gen_tcp, socket: socket}), do: :gen_tcp.close(socket)

  # --- connecting -------------------------------------------------------------

  defp open(%URI{scheme: "wss", host: host, port: port}) do
    host_chars = String.to_charlist(host)

    options = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host_chars,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 4
    ]

    case :ssl.connect(host_chars, port, options, @connect_timeout_ms) do
      {:ok, socket} -> {:ok, :ssl, socket}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  defp open(%URI{scheme: "ws", host: host, port: port}) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.to_charlist()

    case :gen_tcp.connect(host, port, [:binary, active: false], @connect_timeout_ms) do
      {:ok, socket} -> {:ok, :gen_tcp, socket}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  defp handshake(transport, socket, uri, headers) do
    key = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    request = [
      "GET ",
      if(path == "", do: "/", else: path),
      " HTTP/1.1\r\n",
      "Host: ",
      host_header(uri),
      "\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: ",
      key,
      "\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    with :ok <- raw_send(transport, socket, request),
         {:ok, head, leftover} <- read_head(transport, socket, ""),
         :ok <- check_response(head, key) do
      {:ok, leftover}
    else
      {:error, reason} ->
        _ = raw_close(transport, socket)
        {:error, reason}
    end
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    default? = (scheme == "wss" and port == 443) or (scheme == "ws" and port == 80)
    if default?, do: host, else: "#{host}:#{port}"
  end

  defp read_head(transport, socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] when byte_size(acc) > @max_handshake_bytes ->
        {:error, :handshake_too_large}

      [_partial] ->
        case raw_recv(transport, socket) do
          {:ok, data} -> read_head(transport, socket, acc <> data)
          {:error, reason} -> {:error, {:handshake_failed, reason}}
        end
    end
  end

  defp check_response(head, key) do
    [status_line | header_lines] = String.split(head, "\r\n")
    expected = :crypto.hash(:sha, key <> @guid) |> Base.encode64()

    headers =
      Map.new(header_lines, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> {String.downcase(String.trim(name)), String.trim(value)}
          [name] -> {String.downcase(String.trim(name)), ""}
        end
      end)

    cond do
      not String.starts_with?(status_line, "HTTP/1.1 101") ->
        {:error, {:upgrade_refused, status_code(status_line)}}

      headers["sec-websocket-accept"] != expected ->
        {:error, :bad_accept_key}

      true ->
        :ok
    end
  end

  defp status_code(status_line) do
    case String.split(status_line, " ", parts: 3) do
      [_version, code | _rest] -> code
      _other -> "?"
    end
  end

  defp raw_send(:ssl, socket, data), do: :ssl.send(socket, data)
  defp raw_send(:gen_tcp, socket, data), do: :gen_tcp.send(socket, data)

  defp raw_recv(:ssl, socket), do: :ssl.recv(socket, 0, @connect_timeout_ms)
  defp raw_recv(:gen_tcp, socket), do: :gen_tcp.recv(socket, 0, @connect_timeout_ms)

  defp raw_close(:ssl, socket), do: :ssl.close(socket)
  defp raw_close(:gen_tcp, socket), do: :gen_tcp.close(socket)
end
