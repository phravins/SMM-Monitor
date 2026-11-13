defmodule SmmMonitor.Fetchers.Stream do
  @moduledoc """
  The contract for a platform that pushes posts over a WebSocket.

  `SmmMonitor.Fetchers.Fetcher` covers platforms that are asked for new
  posts on a timer. Some platforms instead send every post the moment it
  is published, over one long-lived connection: Bluesky's Jetstream,
  Discord's Gateway and Mastodon's streaming API. This behaviour
  is the contract for those, and `SmmMonitor.Fetchers.StreamWorker` is the
  process that drives them, the same way `Worker` drives a `Fetcher`.

  As with a fetcher, the module owns no process, socket or timer. It is
  handed decoded messages and its own state, and returns:

    * the posts the message contained, as attrs maps for
      `SmmMonitor.Mention.new/1` (without `:client_id`),
    * any frames to send back (Discord's heartbeat, for example),
    * its new state.

  The worker decides which clients a post belongs to, using each
  client's brand terms (`SmmMonitor.Matching`), because a stream sends
  everything and knows nothing about clients.

  ## Callbacks with defaults

  `use SmmMonitor.Fetchers.Stream, platform: :name` provides defaults for
  everything except `url/2` and `handle_message/2`:

    * `ready?/1` is false, so the platform shows as not connected until
      the module says otherwise.
    * nothing to prepare before connecting, no extra headers, no frames
      on open, no heartbeat, no idle timeout.
    * `tick/1`, `on_disconnect/1` and `enrich/2` pass the state through.
    * a close from the server, or a failed connection attempt,
      reconnects; this end closes with 1000; a message may be up to 1 MB.
    * `mock_fetch/2` uses the shared fixtures, as a fetcher's does.
  """

  alias SmmMonitor.Fetchers.Fetcher

  @typedoc "Whatever the platform carries between messages and connections."
  @type state :: term()

  @typedoc "A text frame to send to the server, already encoded."
  @type frame :: iodata()

  @doc "The platform this module streams."
  @callback platform() :: atom()

  @doc "Label shown in the TUI."
  @callback display_name() :: String.t()

  @doc "Whether to connect: the platform is switched on and configured."
  @callback ready?(Fetcher.context()) :: boolean()

  @doc "Initial state, built once when the worker starts."
  @callback init_state(Fetcher.context()) :: state()

  @doc """
  Work to do before each connection attempt, in the worker process: a
  lookup the URL depends on, such as asking a Mastodon server which host
  its streaming API is on. Keep it short and cache what it learns in the
  state; it runs before every attempt.

  `{:error, reason, state}` counts as a failed attempt and is retried
  with the usual back-off.
  """
  @callback prepare(Fetcher.context(), state()) :: {:ok, state()} | {:error, term(), state()}

  @doc """
  The URL to connect to. Called before every connection, so it can carry
  a resume cursor.
  """
  @callback url(Fetcher.context(), state()) :: {:ok, String.t()} | {:error, term()}

  @doc "Extra request headers for the handshake."
  @callback headers(state()) :: [{String.t(), String.t()}]

  @doc "Frames to send as soon as the connection is open."
  @callback on_open(state()) :: {[frame()], state()}

  @doc """
  Handles one decoded JSON message.

    * `{:ok, posts, frames, state}` - carry on.
    * `{:reconnect, state}` - close this connection and open a new one.
    * `{:stop, reason, state}` - a problem a retry will not fix (a
      revoked token, for example). The worker stops connecting, shows
      `reason`, and tries again only after a long pause.
  """
  @callback handle_message(term(), state()) ::
              {:ok, [map()], [frame()], state()}
              | {:reconnect, state()}
              | {:stop, term(), state()}

  @doc "How often to call `heartbeat/1`, in ms, or nil for never."
  @callback heartbeat_ms(state()) :: pos_integer() | nil

  @doc """
  Frames to send on each heartbeat, or `{:reconnect, state}` when the
  connection has gone quiet in a way the platform can detect (Discord's
  missing heartbeat acknowledgement).

  `heartbeat_ms/1` is asked again after every message, so a platform that
  only learns its interval from the server (Discord's Hello) can start
  beating then.
  """
  @callback heartbeat(state()) :: {[frame()], state()} | {:reconnect, state()}

  @doc """
  Reconnect when nothing has arrived for this long, in ms, or nil.

  A busy firehose that goes quiet for a minute has almost certainly
  stalled without closing, which TCP alone can take hours to notice.
  """
  @callback idle_timeout_ms() :: pos_integer() | nil

  @doc """
  Called every few seconds while live, for periodic work such as saving a
  cursor or catching up on posts missed while disconnected. Any posts
  returned are matched and stored like ones from the stream.
  """
  @callback tick(state()) :: {[map()], state()}

  @doc """
  The server closed the connection with `code` (nil when it gave none).

  `{:reconnect, state}` reconnects with back-off, as for any drop.
  `{:stop, reason, state}` is for a code that says retrying cannot help,
  such as a rejected token.
  """
  @callback handle_close(integer() | nil, state()) ::
              {:reconnect, state()} | {:stop, term(), state()}

  @doc """
  A connection attempt failed before the stream opened: `reason` is what
  `SmmMonitor.WebSocket.connect/2` returned, such as
  `{:upgrade_refused, "401"}` when the server turned the token away
  (the status code is a string, as it came off the wire).

  `{:reconnect, state}` retries with back-off. `{:stop, reason, state}` is
  for a refusal that retrying cannot fix.
  """
  @callback handle_connect_error(term(), state()) ::
              {:reconnect, state()} | {:stop, term(), state()}

  @doc """
  The close code to send when this end closes the connection. 1000 by
  default; Discord needs another code to keep its session resumable.
  """
  @callback close_code(state()) :: pos_integer()

  @doc "The largest single message accepted, in bytes. 1 MB by default."
  @callback max_message_bytes() :: pos_integer()

  @doc "Called when a connection ends, for any reason."
  @callback on_disconnect(state()) :: state()

  @doc """
  Called on matched posts just before they are stored, in batches.

  The place for a lookup that is too slow to do per message, such as
  turning Bluesky's account ids into readable handles.
  """
  @callback enrich([map()], state()) :: {[map()], state()}

  @doc "Fixture posts for demo mode, for one client."
  @callback mock_fetch(Fetcher.context(), state()) :: Fetcher.result()

  @optional_callbacks heartbeat: 1

  defmacro __using__(opts) do
    platform = Keyword.fetch!(opts, :platform)

    display_name =
      Keyword.get(opts, :display_name, platform |> Atom.to_string() |> String.capitalize())

    quote do
      @behaviour SmmMonitor.Fetchers.Stream

      @impl true
      def platform, do: unquote(platform)

      @impl true
      def display_name, do: unquote(display_name)

      @impl true
      def ready?(_context), do: false

      @impl true
      def init_state(_context), do: nil

      @impl true
      def prepare(_context, state), do: {:ok, state}

      @impl true
      def headers(_state), do: []

      @impl true
      def on_open(state), do: {[], state}

      @impl true
      def heartbeat_ms(_state), do: nil

      @impl true
      def idle_timeout_ms, do: nil

      @impl true
      def tick(state), do: {[], state}

      @impl true
      def handle_close(_code, state), do: {:reconnect, state}

      @impl true
      def handle_connect_error(_reason, state), do: {:reconnect, state}

      @impl true
      def close_code(_state), do: 1000

      @impl true
      def max_message_bytes, do: 1_048_576

      @impl true
      def on_disconnect(state), do: state

      @impl true
      def enrich(posts, state), do: {posts, state}

      @impl true
      def mock_fetch(context, state) do
        {:ok, mentions} = SmmMonitor.Fetchers.Fixtures.fetch(context)
        {:ok, mentions, state}
      end

      defoverridable ready?: 1,
                     init_state: 1,
                     prepare: 2,
                     headers: 1,
                     on_open: 1,
                     heartbeat_ms: 1,
                     idle_timeout_ms: 0,
                     tick: 1,
                     handle_close: 2,
                     handle_connect_error: 2,
                     close_code: 1,
                     max_message_bytes: 0,
                     on_disconnect: 1,
                     enrich: 2,
                     mock_fetch: 2,
                     display_name: 0
    end
  end
end
