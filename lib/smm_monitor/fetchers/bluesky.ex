defmodule SmmMonitor.Fetchers.Bluesky do
  @moduledoc """
  Bluesky, live, through Jetstream.

  Jetstream is a public service run by Bluesky that turns the network's
  firehose into plain JSON over a WebSocket. Asking it for
  `app.bsky.feed.post` gets every new post on Bluesky about a second
  after it is written, with no account and no API key. Each post is
  matched against every client's brand terms here
  (`SmmMonitor.Matching`); everything else is thrown away unread.

  ## Turning it on

  Off by default, because the stream uses bandwidth around the clock
  whether or not anything matches (see `docs/platforms.md`). Set
  `SMM_BLUESKY_ENABLED=true`. `SMM_BLUESKY_JETSTREAM_URL` points it at a
  different Jetstream instance, including one you run yourself; it must
  be `wss://`.

  ## Catching up after downtime

  Every message carries `time_us`, the moment Jetstream saw it. The last
  one is saved to `bluesky.cursor` next to the database every 10
  seconds, and reconnecting asks Jetstream to replay from a few seconds
  before it. A restart or a dropped connection therefore loses nothing,
  up to an hour back; anything replayed twice is dropped by the store's
  de-duplication.

  ## Names

  The stream identifies authors by DID (`did:plc:...`), not handle. When
  matched posts are stored, the DIDs not yet known are looked up in one
  batch through Bluesky's public profile API and shown as `@handle`. If
  that lookup fails, the DID is shown instead; nothing is lost.
  """

  use SmmMonitor.Fetchers.Stream, platform: :bluesky, display_name: "Bluesky"

  require Logger

  alias SmmMonitor.WebSocket

  @default_url "wss://jetstream2.us-east.bsky.network/subscribe"
  @collection "app.bsky.feed.post"
  @profiles_url "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfiles"

  # Replay from a little before the saved position, so a message that
  # was in flight when the connection dropped is not missed.
  @resume_overlap_us 5_000_000
  # And never from further back than this: replaying a day of the whole
  # network to find a handful of matches would take a long time and a lot
  # of bandwidth.
  @max_rewind_us 3_600_000_000
  @save_every_ms 10_000

  @profiles_per_request 25
  @max_lookups_per_flush 50
  @max_cached_handles 5_000

  @did ~r/\Adid:[a-z]+:[A-Za-z0-9._:%-]{1,256}\z/
  @rkey ~r/\A[A-Za-z0-9._~:-]{1,512}\z/
  @handle ~r/\A[A-Za-z0-9.-]{1,253}\z/

  defmodule State do
    @moduledoc false
    defstruct cursor: nil, saved_cursor: nil, last_save_mono: nil, cursor_file: nil, handles: %{}
  end

  @impl true
  def ready?(_context), do: Keyword.get(settings(), :enabled, false) == true

  @impl true
  def init_state(_context) do
    file = cursor_file()
    cursor = read_cursor(file)
    %State{cursor: cursor, saved_cursor: cursor, cursor_file: file}
  end

  @impl true
  def url(_context, %State{} = state) do
    base = Keyword.get(settings(), :jetstream_url) || @default_url

    case WebSocket.parse_url(base) do
      {:ok, uri} ->
        query =
          (uri.query || "")
          |> URI.decode_query()
          |> Map.put("wantedCollections", @collection)
          |> put_cursor(state.cursor)

        {:ok, URI.to_string(%{uri | query: URI.encode_query(query)})}

      {:error, reason} ->
        {:error, {:jetstream_url, reason}}
    end
  end

  defp put_cursor(query, nil), do: query

  defp put_cursor(query, cursor) do
    now_us = System.os_time(:microsecond)
    resume = max(cursor - @resume_overlap_us, now_us - @max_rewind_us)
    Map.put(query, "cursor", Integer.to_string(resume))
  end

  @impl true
  def idle_timeout_ms, do: 60_000

  @impl true
  def handle_message(message, %State{} = state) do
    state = advance(state, message)

    case message do
      %{
        "kind" => "commit",
        "did" => did,
        "commit" => %{
          "operation" => "create",
          "collection" => @collection,
          "rkey" => rkey,
          "record" => %{"text" => text}
        }
      }
      when is_binary(did) and is_binary(rkey) and is_binary(text) ->
        {:ok, List.wrap(post(did, rkey, text, message["time_us"])), [], state}

      # Handle changes come through the same stream; keeping them saves
      # a lookup later.
      %{"kind" => "identity", "identity" => %{"did" => did, "handle" => handle}} ->
        {:ok, [], [], remember_handles(state, [{did, handle}])}

      _other ->
        {:ok, [], [], state}
    end
  end

  # Parsing is separate from the stream so it can be tested on its own.
  @doc false
  def post(did, rkey, text, time_us) do
    if Regex.match?(@did, did) and Regex.match?(@rkey, rkey) do
      %{
        id: did <> "/" <> rkey,
        platform: :bluesky,
        author: did,
        text: text,
        # Built from the parts, never taken from the post, so a link
        # always goes to bsky.app.
        url: "https://bsky.app/profile/#{did}/post/#{rkey}",
        # When Jetstream saw the post. The post's own createdAt is set by
        # the author's app and can be anything.
        timestamp: timestamp(time_us)
      }
    end
  end

  defp timestamp(time_us) when is_integer(time_us) and time_us > 0, do: div(time_us, 1000)
  defp timestamp(_time_us), do: DateTime.utc_now()

  defp advance(state, %{"time_us" => time_us}) when is_integer(time_us),
    do: %{state | cursor: max(time_us, state.cursor || 0)}

  defp advance(state, _message), do: state

  @impl true
  def tick(%State{} = state) do
    now = System.monotonic_time(:millisecond)

    if state.last_save_mono == nil or now - state.last_save_mono >= @save_every_ms do
      save_cursor(%{state | last_save_mono: now})
    else
      state
    end
  end

  @impl true
  def on_disconnect(%State{} = state), do: save_cursor(state)

  # --- handles ------------------------------------------------------------------

  @impl true
  def enrich(posts, %State{} = state) do
    state =
      if Keyword.get(settings(), :resolve_handles, true) do
        posts
        |> Enum.map(& &1.author)
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(state.handles, &1))
        |> Enum.take(@max_lookups_per_flush)
        |> Enum.chunk_every(@profiles_per_request)
        |> Enum.reduce(state, fn dids, state -> remember_handles(state, lookup(dids)) end)
      else
        state
      end

    {Enum.map(posts, &named(&1, state.handles)), state}
  end

  defp named(post, handles) do
    case Map.get(handles, post.author) do
      nil -> post
      handle -> %{post | author: "@" <> handle}
    end
  end

  defp lookup(dids) do
    query = Enum.map_join(dids, "&", &("actors=" <> URI.encode_www_form(&1)))

    request =
      Req.new(
        [
          url: @profiles_url <> "?" <> query,
          receive_timeout: 3_000,
          connect_options: [timeout: 3_000],
          retry: false
        ] ++ Keyword.get(settings(), :req_options, [])
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"profiles" => profiles}}} when is_list(profiles) ->
        for %{"did" => did, "handle" => handle} <- profiles, do: {did, handle}

      {:ok, %{status: status}} ->
        Logger.debug("bluesky: handle lookup returned HTTP #{status}")
        []

      {:error, reason} ->
        Logger.debug("bluesky: handle lookup failed: #{inspect(reason)}")
        []
    end
  end

  defp remember_handles(state, pairs) do
    valid =
      for {did, handle} <- pairs,
          is_binary(did) and is_binary(handle),
          Regex.match?(@handle, handle),
          handle != "handle.invalid",
          into: %{},
          do: {did, String.downcase(handle)}

    # Crude but bounded: a cache that reaches the cap starts again.
    handles = if map_size(state.handles) > @max_cached_handles, do: %{}, else: state.handles
    %{state | handles: Map.merge(handles, valid)}
  end

  # --- the cursor file ------------------------------------------------------------

  defp cursor_file do
    case Keyword.fetch(settings(), :cursor_file) do
      {:ok, file} ->
        file

      :error ->
        database = Application.get_env(:smm_monitor, SmmMonitor.Repo, [])[:database]
        if database, do: Path.join(Path.dirname(database), "bluesky.cursor")
    end
  end

  defp read_cursor(nil), do: nil

  defp read_cursor(file) do
    with {:ok, contents} <- File.read(file),
         {cursor, ""} when cursor > 0 <- contents |> String.trim() |> Integer.parse() do
      cursor
    else
      _missing_or_bad -> nil
    end
  end

  defp save_cursor(%State{cursor_file: nil} = state), do: state
  defp save_cursor(%State{cursor: nil} = state), do: state
  defp save_cursor(%State{cursor: same, saved_cursor: same} = state), do: state

  defp save_cursor(state) do
    file = state.cursor_file
    temporary = file <> ".tmp"

    result =
      with :ok <- SmmMonitor.Paths.ensure_private_dir(Path.dirname(file), only_if_created: true),
           :ok <- File.write(temporary, Integer.to_string(state.cursor)),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, file)
      end

    case result do
      :ok ->
        %{state | saved_cursor: state.cursor}

      {:error, reason} ->
        Logger.warning("bluesky: could not save the stream position: #{inspect(reason)}")
        state
    end
  end

  defp settings, do: Application.get_env(:smm_monitor, __MODULE__, [])
end
