defmodule SmmMonitor.Alerts do
  @moduledoc """
  Watches for spikes in negative sentiment and tells someone.

  Everything else in this app answers "what is being said?". This is the
  part that answers "is something wrong *right now*?" — the difference
  between a dashboard someone remembers to open and one that finds them.

  Every minute it compares each **client's** recent negative mentions on
  each platform against that client's own normal for that platform,
  drawn from stored history, and raises an alert when the two diverge far
  enough.

  Per client, not per platform alone: one client having a bad afternoon
  averaged against four quiet ones is a number nobody can act on, and the
  first thing anyone asks about an alert is whose brand it concerns.
  `SmmMonitor.Alerts.Detector` holds the judgement and is pure; this
  process holds the clock, the cooldowns and the notifier fan-out.

  ## Cooldowns

  A spike lasts longer than one evaluation, so without a cooldown a
  single bad afternoon would post to Slack sixty times an hour. Each
  client-and-platform alert is therefore rate-limited (one hour by
  default), and the cooldown clears once that pair falls back below
  threshold — so a genuinely new spike after a recovery alerts again
  immediately, and one client's spike never silences another's.

  ## Failure policy

  Alerting is the last thing that should be allowed to break collection.
  A failing notifier is logged and the others still run; a database that
  cannot answer means no baseline, which the detector reads as "still
  warming up" rather than as a reason to alert.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Alerts.{Alert, Detector}
  alias SmmMonitor.Alerts.Notifiers.{LogNotifier, WebhookNotifier}
  alias SmmMonitor.{Client, Clients, Monitor, Persistence}

  @evaluate_interval_ms :timer.minutes(1)
  @default_window_ms :timer.hours(1)
  @default_baseline_days 7
  @default_cooldown_ms :timer.hours(1)
  # Keep enough for the dashboard to show a short history.
  @max_recent 50

  defmodule State do
    @moduledoc false
    defstruct interval_ms: nil,
              # %{{platform, kind} => DateTime} of the last alert sent.
              cooldowns: %{},
              recent: [],
              evaluations: 0,
              raised: 0,
              last_evaluated_at: nil
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether alerting runs at all."
  @spec enabled?() :: boolean()
  def enabled?, do: SmmMonitor.config(:alerts_enabled, true)

  @doc """
  Alerts raised recently, newest first.

  Read by the dashboard's banner. Returns `[]` if alerting isn't running,
  so callers never have to check first.
  """
  @spec recent(GenServer.server(), pos_integer(), String.t() | :all) :: [Alert.t()]
  def recent(server \\ __MODULE__, limit \\ 10, client \\ :all) do
    GenServer.call(server, {:recent, limit, client})
  catch
    :exit, _reason -> []
  end

  @doc "Runs an evaluation immediately rather than waiting for the timer."
  @spec evaluate_now(GenServer.server()) :: {:ok, [Alert.t()]}
  def evaluate_now(server \\ __MODULE__), do: GenServer.call(server, :evaluate, 30_000)

  @doc "Counters, for tests and the dashboard."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc "Forgets all cooldowns and history. Test helper."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "The notifiers that are configured and will be called."
  @spec active_notifiers() :: [module()]
  def active_notifiers do
    :smm_monitor
    |> Application.get_env(:alert_notifiers, [LogNotifier, WebhookNotifier])
    |> Enum.filter(&configured?/1)
  end

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @evaluate_interval_ms)

    unless Keyword.get(opts, :schedule?, true) == false do
      # First pass a little after boot: the fetchers need a poll or two
      # before "the last hour" means anything.
      Process.send_after(
        self(),
        :evaluate,
        Keyword.get(opts, :initial_delay_ms, :timer.seconds(45))
      )
    end

    {:ok, %State{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    {_alerts, state} = run(state)
    Process.send_after(self(), :evaluate, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:evaluate, _from, state) do
    {alerts, state} = run(state)
    {:reply, {:ok, alerts}, state}
  end

  @impl true
  def handle_call({:recent, limit, client}, _from, state) do
    alerts =
      state.recent
      |> Enum.filter(&matches_client?(&1, client))
      |> Enum.take(limit)

    {:reply, alerts, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       evaluations: state.evaluations,
       raised: state.raised,
       last_evaluated_at: state.last_evaluated_at,
       cooling_down: Map.keys(state.cooldowns),
       notifiers: active_notifiers()
     }, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %State{interval_ms: state.interval_ms}}
  end

  # --- internals ------------------------------------------------------------
  # An alert raised before clients existed has no client_id; showing it
  # everywhere beats hiding it.
  defp matches_client?(_alert, :all), do: true
  defp matches_client?(%Alert{client_id: nil}, _client), do: true
  defp matches_client?(%Alert{client_id: id}, id), do: true
  defp matches_client?(%Alert{}, _client), do: false

  defp run(state) do
    now = DateTime.utc_now()
    pairs = for client <- clients(), platform <- SmmMonitor.platforms(), do: {client, platform}

    {alerts, state} =
      Enum.reduce(pairs, {[], state}, fn {client, platform}, {alerts, state} ->
        case evaluate_platform(client, platform, now) do
          {:alert, alert} -> raise_alert(with_client(alert, client), alerts, state, now)
          {:ok, _reason} -> {alerts, clear_cooldown(state, client, platform)}
        end
      end)

    {Enum.reverse(alerts), %{state | evaluations: state.evaluations + 1, last_evaluated_at: now}}
  end

  # Paused clients are not polled, so their window empties and every
  # evaluation would read as a recovery. Skipping them keeps the counters
  # honest about what is actually being watched.
  defp clients do
    Clients.active()
  catch
    :exit, _reason -> []
  end

  defp with_client(alert, %Client{} = client) do
    %{alert | client_id: client.id, client_name: client.name}
  end

  defp evaluate_platform(%Client{id: client_id}, platform, now) do
    window_ms = SmmMonitor.config(:alert_window_ms, @default_window_ms)
    baseline_days = SmmMonitor.config(:alert_baseline_days, @default_baseline_days)

    current = Monitor.stats(platform, window_ms, client_id)
    {baseline, history_ms} = baseline(client_id, platform, baseline_days, window_ms, now)

    Detector.evaluate(
      %{
        platform: platform,
        window_ms: window_ms,
        observed_negative: current.negative,
        observed_total: current.count,
        baseline_negative: baseline,
        history_ms: history_ms
      },
      now: now
    )
  end

  # The baseline deliberately comes from stored history rather than ETS:
  # ETS holds a rolling window measured in hours, which is not long enough
  # to say what "normal" looks like.
  defp baseline(client_id, platform, baseline_days, window_ms, now) do
    history_ms = baseline_days * 24 * 3_600 * 1_000
    cutoff = DateTime.add(now, -history_ms, :millisecond)

    counts = Persistence.sentiment_counts_since(cutoff, platform, client: client_id)
    available_ms = available_history_ms(client_id, platform, now, history_ms)

    if counts.total == 0 do
      {nil, available_ms}
    else
      {Detector.baseline_for_window(counts.negative, available_ms, window_ms), available_ms}
    end
  end

  # How much history there actually is, capped at the requested window. A
  # day-old install must not have its 24 hours treated as a week, or the
  # baseline would read seven times lower than reality and everything
  # would look like a spike.
  defp available_history_ms(client_id, platform, now, requested_ms) do
    case Persistence.earliest_timestamp(platform, client: client_id) do
      nil -> 0
      earliest -> now |> DateTime.diff(earliest, :millisecond) |> max(0) |> min(requested_ms)
    end
  end

  defp raise_alert(alert, alerts, state, now) do
    if cooling_down?(state, alert, now) do
      {alerts, state}
    else
      notify(alert)

      state = %{
        state
        | cooldowns: Map.put(state.cooldowns, Alert.key(alert), now),
          recent: Enum.take([alert | state.recent], @max_recent),
          raised: state.raised + 1
      }

      {[alert | alerts], state}
    end
  end

  defp cooling_down?(state, alert, now) do
    cooldown_ms = SmmMonitor.config(:alert_cooldown_ms, @default_cooldown_ms)

    case Map.get(state.cooldowns, Alert.key(alert)) do
      nil -> false
      last -> DateTime.diff(now, last, :millisecond) < cooldown_ms
    end
  end

  # Recovering below threshold clears the cooldown, so a genuinely new
  # spike after a quiet spell alerts immediately rather than waiting out
  # the remainder of an old one.
  defp clear_cooldown(state, %Client{id: client_id}, platform) do
    %{state | cooldowns: Map.delete(state.cooldowns, {client_id, platform, :negative_spike})}
  end

  # Each channel is called inside its own try: one broken notifier must
  # not stop the alert reaching the others.
  defp notify(alert) do
    Enum.each(active_notifiers(), &notify_via(&1, alert))
  end

  defp notify_via(notifier, alert) do
    notifier.notify(alert)
  rescue
    error -> Logger.warning("alerts: #{inspect(notifier)} failed (#{inspect(error)})")
  catch
    :exit, reason -> Logger.warning("alerts: #{inspect(notifier)} exited (#{inspect(reason)})")
  end

  defp configured?(notifier) do
    not function_exported?(notifier, :configured?, 0) or notifier.configured?()
  end
end
