defmodule SmmMonitor.Fetchers.StreamWorker do
  @moduledoc """
  One GenServer per streaming platform: keeps a WebSocket open, matches
  what arrives against every client's brand terms, and stores the hits.

  It is the streaming counterpart of `SmmMonitor.Fetchers.Worker`, and
  reports its status in the same shape so the dashboard can show either
  without caring which it is.

  ## The loop

    * Every 5 seconds a `:check` runs. It rebuilds the brand-term matcher
      if clients changed, works out the mode (live, demo or not
      configured) and connects or disconnects to match it. A client
      added on the clients screen is therefore matched within 5 seconds,
      without reconnecting.
    * Connecting happens in a short-lived task, so a slow TLS handshake
      never blocks the dashboard asking for status. The task hands the
      finished socket to this process.
    * Data arrives as `{:ssl, socket, bytes}` messages, one chunk at a
      time (`active: :once`), so a burst cannot flood the mailbox.
    * Matched posts are buffered and written to `SmmMonitor.Monitor` once
      a second, or as soon as 100 are waiting. A firehose therefore costs
      one write a second, not one per post.

  ## Failure policy

  A dropped connection, a refused handshake or a malformed frame is
  normal on the open internet. Each is recorded, and the worker
  reconnects after 1, 2, 4 ... up to 60 seconds, plus up to a second of
  random jitter so many installs do not reconnect in lockstep after an
  outage. The delay resets once a connection delivers data.

  A platform that says retrying cannot help (`{:stop, reason, state}`,
  for a revoked token) is not retried for 10 minutes, and the reason is
  shown on screen.

  As with `Worker`, an exception is not caught: the worker crashes and
  its platform supervisor starts it again with a clean slate.
  """

  use GenServer

  require Logger

  alias SmmMonitor.{Clients, Matching, Monitor, WebSocket}

  @check_ms 5_000
  @flush_ms 1_000
  @flush_at 100
  @mock_ms 15_000
  @max_backoff_ms 60_000
  @stop_retry_ms :timer.minutes(10)
  @startup_jitter_ms 1_000

  # A stream has no poll interval. The dashboard marks a platform stale
  # when nothing has worked for three intervals, so this is what makes a
  # stream that has been silent for 90 seconds show as stale.
  @status_interval_ms 30_000

  defmodule State do
    @moduledoc false
    defstruct [
      :module,
      :platform,
      :opts,
      :platform_state,
      :matcher,
      # The client list the matcher was built from, to rebuild only on change.
      :matcher_source,
      :ws,
      # {tag, monitor} of the connect attempt while one is running.
      :connecting,
      :reconnect_timer,
      :heartbeat_timer,
      :mock_timer,
      # Monotonic ms of the last data from the server, for the idle timeout.
      :last_frame_mono,
      mode: :unconfigured,
      # :idle | :connecting | :connected | :reconnecting | :stopped
      connection: :idle,
      attempts: 0,
      connects: 0,
      # Posts matched but not yet stored, newest first, and their count.
      pending: [],
      pending_count: 0,
      last_success_at: nil,
      last_event_at: nil,
      last_error: nil,
      events_seen: 0,
      matched: 0,
      inserted: 0,
      failures: 0,
      mock_rounds: 0,
      clients_due: 0,
      credentials_warned: false
    ]
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    GenServer.start_link(__MODULE__, opts, name: name(module.platform()))
  end

  @doc "Registered name for a platform's stream worker."
  @spec name(atom()) :: atom()
  def name(platform) do
    Module.concat(__MODULE__, platform |> Atom.to_string() |> Macro.camelize())
  end

  @doc """
  Current status, in the shape `SmmMonitor.Fetchers.Worker.status/1`
  returns, plus `transport: :stream`, `connection`, `connected?`,
  `last_event_at`, `events_seen` and `matched`.

  `last_success_at` is when data last arrived. `next_poll_at` is always
  nil, because nothing is scheduled: posts arrive when they are written.
  """
  @spec status(atom()) :: map() | :unavailable
  def status(platform) do
    GenServer.call(name(platform), :status)
  catch
    :exit, _reason -> :unavailable
  end

  @doc """
  Re-checks the configuration now and, if a reconnect is waiting out its
  back-off, connects immediately. Does nothing if the worker is not
  running.
  """
  @spec poll_now(atom()) :: :ok
  def poll_now(platform) do
    if Process.whereis(name(platform)), do: GenServer.cast(name(platform), :poll_now)
    :ok
  end

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)

    state = %State{module: module, platform: module.platform(), opts: Keyword.get(opts, :opts, [])}
    state = %{state | platform_state: module.init_state(build_context(state, nil))}

    Process.send_after(self(), :check, :rand.uniform(@startup_jitter_ms))
    Process.send_after(self(), :flush, @flush_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      platform: state.platform,
      display_name: state.module.display_name(),
      mode: state.mode,
      transport: :stream,
      connection: state.connection,
      connected?: state.connection == :connected,
      poll_count: state.connects,
      last_poll_at: state.last_event_at,
      last_success_at: state.last_success_at,
      next_poll_at: nil,
      last_error: state.last_error,
      inserted: state.inserted,
      failures: state.failures,
      interval_ms: @status_interval_ms,
      clients_polled: length(state.matcher.clients),
      clients_due: state.clients_due,
      last_event_at: state.last_event_at,
      events_seen: state.events_seen,
      matched: state.matched
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    state = check(state)

    state =
      if state.mode == :live and state.connection in [:reconnecting, :stopped] do
        state |> cancel(:reconnect_timer) |> connect()
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    {:noreply, check(state)}
  end

  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, flush(state)}
  end

  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    if state.mode == :live and state.connection in [:reconnecting, :stopped] do
      {:noreply, connect(state)}
    else
      {:noreply, %{state | connection: :idle}}
    end
  end

  def handle_info(:heartbeat, %State{ws: nil} = state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    {frames, platform_state} = state.module.heartbeat(state.platform_state)
    state = %{state | platform_state: platform_state}
    send_frames(state, frames)
    {:noreply, schedule_heartbeat(state)}
  end

  def handle_info(:mock_round, state) do
    state = %{state | mock_timer: nil}
    if state.mode == :mock, do: {:noreply, mock_round(state)}, else: {:noreply, state}
  end

  # The connect attempt finished. The result is sent before the process
  # exits, so it always arrives ahead of the monitor's :DOWN.
  def handle_info({:connect_result, tag, result}, %State{connecting: {tag, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, connected(%{state | connecting: nil}, result)}
  end

  # An attempt that was abandoned (the mode changed while it ran). Its
  # socket now belongs to this process, so close it rather than leak it.
  def handle_info({:connect_result, _tag, {:ok, ws}}, state) do
    WebSocket.close(ws)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %State{connecting: {_tag, monitor}} = state
      ) do
    {:noreply, connected(%{state | connecting: nil}, {:error, {:connect_crashed, reason}})}
  end

  def handle_info({transport, socket, data}, %State{ws: %{socket: socket}} = state)
      when transport in [:ssl, :tcp] do
    {:noreply, received(state, data)}
  end

  def handle_info({closed, socket}, %State{ws: %{socket: socket}} = state)
      when closed in [:ssl_closed, :tcp_closed] do
    {:noreply, disconnected(state, :closed_by_server)}
  end

  def handle_info({error, socket, reason}, %State{ws: %{socket: socket}} = state)
      when error in [:ssl_error, :tcp_error] do
    {:noreply, disconnected(state, {:socket_error, reason})}
  end

  # Leftovers from a socket that has already been replaced, or a task
  # result that arrived after the connection attempt was abandoned.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %State{} = state -> %{state | platform_state: redacted(state.platform_state)}
      other -> other
    end)
  end

  defp redacted(%module{}), do: "#" <> inspect(module) <> "<redacted>"
  defp redacted(nil), do: nil
  defp redacted(_other), do: "<redacted>"

  # --- the periodic check -----------------------------------------------------

  defp check(state) do
    clients = active_clients()
    state = refresh_matcher(%{state | clients_due: length(clients)}, clients)
    {mode, state} = resolve_mode(state, build_context(state, nil))
    state = %{state | mode: mode}

    case mode do
      :live -> live_check(state)
      :mock -> state |> drop_connection(:idle) |> ensure_mock()
      :unconfigured -> %{drop_connection(state, :idle) | last_success_at: DateTime.utc_now()}
    end
  end

  defp live_check(state) do
    cond do
      # Nobody to match for: a firehose with no client is pure cost.
      Matching.empty?(state.matcher) ->
        %{drop_connection(state, :idle) | last_success_at: DateTime.utc_now()}

      state.connection == :idle ->
        connect(state)

      state.connection == :connected and idle?(state) ->
        Logger.info("#{state.platform}: no data for a while, reconnecting")
        state |> disconnected(:idle_timeout)

      state.connection == :connected ->
        %{state | platform_state: state.module.tick(state.platform_state)}

      true ->
        state
    end
  end

  defp idle?(%State{last_frame_mono: nil}), do: false

  defp idle?(state) do
    case state.module.idle_timeout_ms() do
      nil -> false
      timeout -> System.monotonic_time(:millisecond) - state.last_frame_mono > timeout
    end
  end

  defp refresh_matcher(%State{matcher_source: clients} = state, clients) when state.matcher != nil,
    do: state

  defp refresh_matcher(state, clients),
    do: %{state | matcher: Matching.build(clients), matcher_source: clients}

  # The same order as Worker: demo data only when asked for, live when
  # configured, otherwise nothing (and say so once).
  defp resolve_mode(state, context) do
    cond do
      SmmMonitor.mock_platform?(state.platform) ->
        {:mock, state}

      state.module.ready?(context) ->
        {:live, %{state | credentials_warned: false}}

      true ->
        {:unconfigured, warn_unconfigured(state)}
    end
  end

  defp warn_unconfigured(%State{credentials_warned: true} = state), do: state

  defp warn_unconfigured(state) do
    Logger.info(
      "#{state.platform}: not switched on or not configured, so nothing is being " <>
        "collected from it. See docs/platforms.md."
    )

    %{state | credentials_warned: true}
  end

  # --- connecting -------------------------------------------------------------

  defp connect(state) do
    context = build_context(state, nil)

    case state.module.url(context, state.platform_state) do
      {:ok, url} ->
        headers = state.module.headers(state.platform_state)
        owner = self()
        tag = make_ref()

        # Not linked: a crash in the handshake is a failed attempt, not a
        # reason to take the worker down. The monitor reports it instead.
        {_pid, monitor} =
          spawn_monitor(fn ->
            result =
              with {:ok, ws} <- WebSocket.connect(url, headers: headers),
                   :ok <- WebSocket.controlling_process(ws, owner) do
                {:ok, ws}
              end

            send(owner, {:connect_result, tag, result})
          end)

        %{state | connecting: {tag, monitor}, connection: :connecting}

      {:error, reason} ->
        Logger.warning("#{state.platform}: cannot build the stream URL: #{inspect(reason)}")
        retry_later(%{state | last_error: reason, failures: state.failures + 1})
    end
  end

  defp connected(state, {:ok, ws}) do
    case WebSocket.activate(ws) do
      :ok ->
        Logger.info("#{state.platform}: stream connected")
        state = %{state | ws: ws, connection: :connected, connects: state.connects + 1}
        state = %{state | last_frame_mono: System.monotonic_time(:millisecond)}
        {frames, platform_state} = state.module.on_open(state.platform_state)
        state = %{state | platform_state: platform_state}
        send_frames(state, frames)
        # Bytes that arrived with the handshake response.
        state =
          if ws.buffer != "",
            do: received(%{state | ws: %{ws | buffer: ""}}, ws.buffer),
            else: state

        schedule_heartbeat(state)

      {:error, reason} ->
        connected(state, {:error, reason})
    end
  end

  defp connected(state, {:error, reason}) do
    Logger.warning("#{state.platform}: stream connection failed: #{inspect(reason)}")
    retry_later(%{state | last_error: reason, failures: state.failures + 1})
  end

  defp received(state, data) do
    now = DateTime.utc_now()

    state = %{
      state
      | last_frame_mono: System.monotonic_time(:millisecond),
        last_success_at: now,
        last_error: nil,
        attempts: 0
    }

    case WebSocket.handle_data(state.ws, data) do
      {:ok, ws, messages} ->
        state = Enum.reduce_while(messages, %{state | ws: ws}, &handle_ws_message/2)

        case state do
          %State{ws: nil} -> state
          %State{ws: ws} -> activate(state, ws)
        end

      {:error, reason, ws} ->
        Logger.warning("#{state.platform}: bad data on the stream: #{inspect(reason)}")
        %{state | ws: ws, failures: state.failures + 1} |> disconnected(reason)
    end
  end

  defp activate(state, ws) do
    case WebSocket.activate(ws) do
      :ok -> state
      {:error, reason} -> disconnected(state, {:socket_error, reason})
    end
  end

  defp handle_ws_message({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, decoded} -> platform_message(decoded, state)
      {:error, _reason} -> {:cont, %{state | events_seen: state.events_seen + 1}}
    end
  end

  defp handle_ws_message({:close, code, _reason}, state) do
    {:halt, disconnected(state, {:closed_by_server, code})}
  end

  # Binary frames, pings and pongs: the socket layer already answered
  # pings, and no platform here sends binary.
  defp handle_ws_message(_other, state), do: {:cont, state}

  defp platform_message(decoded, state) do
    state = %{state | events_seen: state.events_seen + 1, last_event_at: DateTime.utc_now()}

    case state.module.handle_message(decoded, state.platform_state) do
      {:ok, posts, frames, platform_state} ->
        state = %{state | platform_state: platform_state}
        send_frames(state, frames)
        {:cont, buffer_posts(state, posts)}

      {:reconnect, platform_state} ->
        {:halt, disconnected(%{state | platform_state: platform_state}, :server_asked_reconnect)}

      {:stop, reason, platform_state} ->
        {:halt, stopped(%{state | platform_state: platform_state}, reason)}
    end
  end

  defp disconnected(state, reason) do
    expected? = reason in [:idle_timeout, :server_asked_reconnect]
    if not expected?, do: Logger.info("#{state.platform}: stream closed: #{inspect(reason)}")

    state
    |> close_socket()
    |> Map.update!(:last_error, fn previous -> if expected?, do: previous, else: reason end)
    |> retry_later()
  end

  defp stopped(state, reason) do
    Logger.error(
      "#{state.platform}: stopped: #{inspect(reason)}. Retrying in " <>
        "#{div(@stop_retry_ms, 60_000)} minutes."
    )

    state = state |> close_socket() |> cancel(:reconnect_timer)

    %{
      state
      | connection: :stopped,
        last_error: reason,
        failures: state.failures + 1,
        reconnect_timer: Process.send_after(self(), :reconnect, @stop_retry_ms)
    }
  end

  defp retry_later(state) do
    delay = min(@max_backoff_ms, 1_000 * Integer.pow(2, min(state.attempts, 6)))
    delay = delay + :rand.uniform(1_000)
    state = cancel(state, :reconnect_timer)

    %{
      state
      | connection: :reconnecting,
        attempts: state.attempts + 1,
        reconnect_timer: Process.send_after(self(), :reconnect, delay)
    }
  end

  # Ends any connection and stops any reconnecting, for when the mode is
  # no longer live.
  defp drop_connection(state, connection) do
    with {_tag, monitor} <- state.connecting, do: Process.demonitor(monitor, [:flush])

    state
    |> close_socket()
    |> cancel(:reconnect_timer)
    |> Map.merge(%{connection: connection, connecting: nil, attempts: 0})
  end

  defp close_socket(%State{ws: nil} = state), do: cancel(state, :heartbeat_timer)

  defp close_socket(state) do
    WebSocket.close(state.ws)
    platform_state = state.module.on_disconnect(state.platform_state)
    cancel(%{state | ws: nil, platform_state: platform_state}, :heartbeat_timer)
  end

  defp schedule_heartbeat(state) do
    state = cancel(state, :heartbeat_timer)

    case state.ws && state.module.heartbeat_ms(state.platform_state) do
      ms when is_integer(ms) and ms > 0 ->
        %{state | heartbeat_timer: Process.send_after(self(), :heartbeat, ms)}

      _none ->
        state
    end
  end

  defp send_frames(%State{ws: nil}, _frames), do: :ok
  defp send_frames(state, frames), do: Enum.each(frames, &WebSocket.send_text(state.ws, &1))

  defp cancel(state, key) do
    case Map.fetch!(state, key) do
      nil ->
        state

      timer ->
        Process.cancel_timer(timer)
        Map.put(state, key, nil)
    end
  end

  # --- matching and storing -------------------------------------------------

  defp buffer_posts(state, []), do: state

  defp buffer_posts(state, posts) do
    {pending, count} =
      Enum.reduce(posts, {state.pending, state.pending_count}, fn post, acc ->
        state.matcher
        |> Matching.clients_for(Map.get(post, :text))
        |> Enum.reduce(acc, fn client_id, {pending, count} ->
          mention = post |> Map.put(:client_id, client_id) |> Map.put(:platform, state.platform)
          {[mention | pending], count + 1}
        end)
      end)

    state = %{
      state
      | pending: pending,
        matched: state.matched + (count - state.pending_count),
        pending_count: count
    }

    if count >= @flush_at, do: flush(state), else: state
  end

  defp flush(%State{pending_count: 0} = state), do: state

  defp flush(state) do
    {mentions, platform_state} =
      state.module.enrich(Enum.reverse(state.pending), state.platform_state)

    {:ok, %{inserted: inserted}} = Monitor.record_fetched(mentions)

    %{
      state
      | pending: [],
        pending_count: 0,
        platform_state: platform_state,
        inserted: state.inserted + inserted
    }
  end

  # --- demo mode ------------------------------------------------------------

  defp ensure_mock(%State{mock_timer: nil} = state),
    do: %{state | mock_timer: Process.send_after(self(), :mock_round, 0)}

  defp ensure_mock(state), do: state

  defp mock_round(state) do
    state =
      Enum.reduce(active_clients(), state, fn client, state ->
        context = %{build_context(state, client) | poll_count: state.mock_rounds}

        case state.module.mock_fetch(context, state.platform_state) do
          {:ok, mentions, platform_state} ->
            {:ok, %{inserted: inserted}} =
              mentions
              |> Enum.map(&Map.put(&1, :client_id, client.id))
              |> Monitor.record_fetched()

            %{state | platform_state: platform_state, inserted: state.inserted + inserted}

          {:error, _reason, platform_state} ->
            %{state | platform_state: platform_state}
        end
      end)

    now = DateTime.utc_now()

    %{
      state
      | mock_rounds: state.mock_rounds + 1,
        last_success_at: now,
        last_event_at: now,
        mock_timer: Process.send_after(self(), :mock_round, @mock_ms)
    }
  end

  # --- context ----------------------------------------------------------------

  defp active_clients do
    Clients.active()
  catch
    :exit, _reason -> []
  end

  defp build_context(state, client) do
    %{
      platform: state.platform,
      client: client,
      keywords: if(client, do: client.keywords, else: []),
      subreddits: [],
      credentials:
        :smm_monitor |> Application.get_env(:credentials, []) |> Keyword.get(state.platform, []),
      opts: state.opts,
      poll_count: state.connects,
      interval_ms: @status_interval_ms
    }
  end
end
