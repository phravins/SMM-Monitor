defmodule SmmMonitor.Fetchers.Worker do
  @moduledoc """
  One polling GenServer per platform.

  The worker is the only process that knows about timers and failure
  handling; the platform module it drives is a pure `fetch(context)`
  function. Keeping it that way means the polling behaviour is written and
  debugged once for every platform we will ever add.

  Each poll:

    1. reads the active clients,
    2. for each, builds a `Fetcher.context` and calls `mock_fetch/2` or
       `fetch/2` depending on mode,
    3. stamps the returned mentions with that client's id and hands them
       to `SmmMonitor.Monitor`,
    4. carries the platform state from one client into the next, and into
       the next poll,
    5. schedules the next poll with `Process.send_after/3`.

  Scheduling happens *after* the work, not on a fixed interval, so a slow
  API can never let polls pile up on top of each other. A fetcher that
  fails with `{:rate_limited, ms}` pushes the next poll out by at least
  that long, so backing off is the fetcher's decision to make and the
  worker's to honour.

  ## One worker per platform, not per client

  Every client is polled from the same worker, in a loop, rather than
  each getting a worker of its own. That is the whole reason the
  rate-limit and quota trackers still work: **an API budget belongs to
  the credential, not to the client**. YouTube's 10,000 daily units and
  X's monthly post cap are spent by whoever holds the key, so one
  process has to own the counting. Splitting clients across workers would
  give each its own private idea of the quota, and four clients would
  quietly spend four times the budget.

  Sharing it has a cost of its own: a client polled first each cycle
  would take the quota and leave the others nothing. So the client list
  is **rotated by poll count** — the client that went first this cycle
  goes last next time — which turns "one client starves the rest" into
  "everyone loses the same fraction of coverage".

  When a fetcher reports a rate limit or spent quota, the cycle stops
  there rather than working through the remaining clients: the limit is
  shared, so the calls would fail anyway, and the clients that missed out
  are the ones the rotation puts first next time.

  ## Failure policy

  A returned `{:error, reason}` is expected (rate limits, a 500, a network
  blip): it is logged, recorded in the worker's status, and the next poll is
  scheduled as normal. An unexpected *exception* is not caught — the worker
  crashes, its own supervisor restarts it with a clean slate, and no other
  platform notices. That is the whole reason each worker has a supervisor
  to itself.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Fetchers.Fetcher
  alias SmmMonitor.{Client, Clients, Monitor}

  # Spread the first poll of each worker over a second so four platforms
  # don't all hit their APIs on the same tick.
  @startup_jitter_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct [
      :module,
      :platform,
      :interval_ms,
      :opts,
      # Whatever the platform module carries between polls (Reddit's OAuth
      # token and rate-limit quota; nil for everyone else).
      :platform_state,
      # The pending :poll timer, so an early poll can replace it instead of
      # adding a second loop.
      :timer,
      poll_count: 0,
      mode: :mock,
      last_poll_at: nil,
      # When the last poll that actually worked finished. last_poll_at moves
      # on every attempt; this one only on success, which is what tells
      # the dashboard whether the numbers on screen are fresh.
      last_success_at: nil,
      next_poll_at: nil,
      # Monotonic ms before which an early poll is not allowed, set when a
      # platform asks us to back off.
      backoff_until: nil,
      last_error: nil,
      inserted: 0,
      failures: 0,
      # Clients covered by the most recent poll, and how many were due.
      # The pair is the honest measure of coverage: "3 of 5" says the
      # cycle stopped early far better than a rate-limit error does.
      clients_polled: 0,
      clients_due: 0,
      # Set once we've logged the "wanted live, no credentials" warning, so
      # a missing key doesn't reprint every 30 seconds.
      credentials_warned: false
    ]
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    GenServer.start_link(__MODULE__, opts, name: name(module.platform()))
  end

  @doc "Registered name for a platform's worker."
  @spec name(atom()) :: atom()
  def name(platform) do
    Module.concat(__MODULE__, platform |> Atom.to_string() |> Macro.camelize())
  end

  @doc """
  Current status of a platform's worker: mode, last poll, failure count.

  Returns `:unavailable` if the worker isn't running, so the TUI can render
  a restarting platform instead of crashing with it.
  """
  @spec status(atom()) :: map() | :unavailable
  def status(platform) do
    GenServer.call(name(platform), :status)
  catch
    :exit, _reason -> :unavailable
  end

  @doc """
  Triggers a poll immediately, without waiting for the timer.

  Used when keys are saved in the setup wizard, so a new key shows data
  in seconds instead of after the next scheduled poll (up to 18 minutes
  for YouTube). The pending timer is replaced, not doubled, and a
  platform that asked for a back-off is left alone. Does nothing if the
  worker is not running.
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

    state = %State{
      module: module,
      platform: module.platform(),
      interval_ms: Keyword.get(opts, :interval_ms, SmmMonitor.config(:poll_interval_ms, 30_000)),
      opts: Keyword.get(opts, :opts, [])
    }

    state = %{state | platform_state: module.init_state(build_context(state, nil))}

    jitter = :rand.uniform(@startup_jitter_ms)

    {:ok,
     %{
       state
       | timer: Process.send_after(self(), :poll, jitter),
         next_poll_at: DateTime.add(DateTime.utc_now(), jitter, :millisecond)
     }}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(%{state | timer: nil})}

  @impl true
  def handle_cast(:poll, state), do: {:noreply, poll(state)}

  def handle_cast(:poll_now, state) do
    if backing_off?(state), do: {:noreply, state}, else: {:noreply, poll(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      platform: state.platform,
      display_name: state.module.display_name(),
      mode: state.mode,
      poll_count: state.poll_count,
      last_poll_at: state.last_poll_at,
      last_success_at: state.last_success_at,
      next_poll_at: state.next_poll_at,
      last_error: state.last_error,
      inserted: state.inserted,
      failures: state.failures,
      interval_ms: state.interval_ms,
      clients_polled: state.clients_polled,
      clients_due: state.clients_due
    }

    {:reply, status, state}
  end

  # Crash reports and :sys.get_status print the whole state. The platform
  # state holds whatever a fetcher caches between polls (Reddit's OAuth
  # token among it), so it is reduced to its type before anything prints.
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

  # --- internals ------------------------------------------------------------

  defp poll(state) do
    clients = rotate(active_clients(), state.poll_count)
    {mode, state} = resolve_mode(state, build_context(state, List.first(clients)))

    {state, retry_after} = poll_clients(clients, mode, state)

    # A fetcher that asked us to back off gets at least that long; otherwise
    # the configured interval stands.
    state = schedule_next(state, max(retry_after || 0, state.interval_ms), retry_after)

    %{state | poll_count: state.poll_count + 1, mode: mode, clients_due: length(clients)}
  end

  defp backing_off?(%State{backoff_until: nil}), do: false

  defp backing_off?(%State{backoff_until: until}),
    do: System.monotonic_time(:millisecond) < until

  # No clients is not a failure — a fresh install between the first boot
  # and someone adding one — but it is worth saying once rather than
  # polling an API for nobody.
  defp poll_clients([], _mode, state) do
    now = DateTime.utc_now()
    {%{state | clients_polled: 0, last_poll_at: now, last_success_at: now}, nil}
  end

  defp poll_clients(clients, mode, state) do
    {state, retry_after, polled} =
      Enum.reduce_while(clients, {state, nil, 0}, fn client, {state, _retry, polled} ->
        case fetch_for(client, mode, state) do
          {:ok, state} ->
            {:cont, {state, nil, polled + 1}}

          {:error, reason, state} ->
            case Fetcher.retry_after(reason) do
              nil ->
                # This client's fetch failed on its own account; the
                # others may still be fine.
                {:cont, {state, nil, polled}}

              wait_ms ->
                # A shared limit: the remaining clients would fail the
                # same way, and the rotation puts them first next cycle.
                log_cycle_stopped(state, client, clients, polled, reason)
                {:halt, {state, wait_ms, polled}}
            end
        end
      end)

    {%{state | clients_polled: polled}, retry_after}
  end

  defp fetch_for(client, mode, state) do
    context = build_context(state, client)

    case do_fetch(state.module, mode, context, state.platform_state) do
      {:ok, mentions, platform_state} ->
        {:ok, %{inserted: inserted}} =
          mentions
          |> Enum.map(&assign_client(&1, client))
          |> Monitor.record_fetched()

        {:ok,
         %{
           state
           | inserted: state.inserted + inserted,
             last_error: nil,
             last_poll_at: DateTime.utc_now(),
             last_success_at: DateTime.utc_now(),
             platform_state: platform_state
         }}

      {:error, reason, platform_state} ->
        Logger.warning("#{state.platform} fetch failed for #{client.id}: #{inspect(reason)}")

        {:error, reason,
         %{
           state
           | failures: state.failures + 1,
             last_error: reason,
             last_poll_at: DateTime.utc_now(),
             platform_state: platform_state
         }}
    end
  end

  # Mentions come back from a fetcher knowing nothing about clients: the
  # fetcher was handed brand terms, not an owner. Stamping happens here so
  # every platform gets it without having to remember to.
  defp assign_client(mention, %Client{id: id}) when is_map(mention) do
    Map.put(mention, :client_id, id)
  end

  # Rotating by poll count is what stops the first client in the list
  # taking the whole shared quota every cycle.
  defp rotate([], _poll_count), do: []

  defp rotate(clients, poll_count) do
    {head, tail} = Enum.split(clients, rem(poll_count, length(clients)))
    tail ++ head
  end

  # An unavailable Clients process (a test running a worker on its own)
  # should not stop the worker polling.
  defp active_clients do
    Clients.active()
  catch
    :exit, _reason -> []
  end

  defp log_cycle_stopped(state, client, clients, polled, reason) do
    skipped = length(clients) - polled

    Logger.info(
      "#{state.platform}: stopping this cycle at #{client.id} (#{inspect(reason)}) - the " <>
        "limit is shared across clients, so #{skipped} client(s) are skipped and go first " <>
        "next cycle"
    )
  end

  # Mock mode is a config flag — global, or per-platform so one platform can
  # go live while the rest stay on fixtures.
  #
  # A platform that should be live but has no credentials collects
  # nothing. It used to invent mentions instead, on the reasoning that an
  # unconfigured key should degrade one tab rather than empty the
  # dashboard. That reasoning was wrong: invented posts are
  # indistinguishable from collected ones once they are in the table, and
  # they are written to the same database, so they skew the trends, the
  # alerts and any report exported afterwards. An empty tab that says
  # why is worth more than a full one that is making it up.
  defp resolve_mode(state, context) do
    cond do
      SmmMonitor.mock_platform?(context.platform) ->
        {:mock, state}

      state.module.ready?(context) ->
        {:live, %{state | credentials_warned: false}}

      true ->
        {:unconfigured, warn_missing_credentials(state)}
    end
  end

  # Logged once per stretch of missing credentials, not on every poll.
  defp warn_missing_credentials(%State{credentials_warned: true} = state), do: state

  defp warn_missing_credentials(state) do
    Logger.warning(
      "#{state.platform}: no credentials, so nothing is being collected from it. " <>
        "Add them with `c` then `S` in the dashboard (Reddit and YouTube), or set " <>
        "this platform's environment variables. Nothing will be invented in the " <>
        "meantime."
    )

    %{state | credentials_warned: true}
  end

  # Collecting nothing is a successful poll, not an error: there is no
  # fault to retry and nothing to report but the absence of a key, which
  # was already logged once.
  defp do_fetch(_module, :unconfigured, _context, platform_state),
    do: {:ok, [], platform_state}

  defp do_fetch(module, :mock, context, platform_state),
    do: module.mock_fetch(context, platform_state)

  defp do_fetch(module, :live, context, platform_state),
    do: module.fetch(context, platform_state)

  # Read fresh on every poll rather than cached at startup: that is what
  # lets a client added or edited in the config screen take effect on the
  # next poll with no restart.
  defp build_context(state, client) do
    %{
      platform: state.platform,
      client: client,
      keywords: keywords_of(client),
      subreddits: subreddits_of(client),
      credentials: credentials(state.platform),
      opts: state.opts,
      poll_count: state.poll_count,
      interval_ms: state.interval_ms
    }
  end

  defp keywords_of(%Client{keywords: keywords}), do: keywords
  defp keywords_of(_client), do: []

  defp subreddits_of(%Client{subreddits: subreddits}), do: subreddits
  defp subreddits_of(_client), do: []

  defp credentials(platform) do
    :smm_monitor
    |> Application.get_env(:credentials, [])
    |> Keyword.get(platform, [])
  end

  defp schedule_next(state, interval_ms, retry_after) do
    if state.timer, do: Process.cancel_timer(state.timer)

    backoff_until =
      if retry_after, do: System.monotonic_time(:millisecond) + retry_after

    %{
      state
      | timer: Process.send_after(self(), :poll, interval_ms),
        next_poll_at: DateTime.add(DateTime.utc_now(), interval_ms, :millisecond),
        backoff_until: backoff_until
    }
  end

  @doc false
  @spec context_for(module(), keyword()) :: Fetcher.context()
  def context_for(module, opts \\ []) do
    client = Keyword.get(opts, :client) || List.first(active_clients())

    %{
      platform: module.platform(),
      client: client,
      keywords: Keyword.get(opts, :keywords) || keywords_of(client),
      subreddits: Keyword.get(opts, :subreddits) || subreddits_of(client),
      credentials: credentials(module.platform()),
      opts: Keyword.drop(opts, [:client, :keywords, :subreddits]),
      poll_count: 0,
      interval_ms: SmmMonitor.config(:poll_interval_ms, 30_000)
    }
  end
end
