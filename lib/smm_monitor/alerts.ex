defmodule SmmMonitor.Alerts do
  @moduledoc """
  Watches every client's mentions and tells someone when they turn.

  Everything else in this app answers "what is being said?". This is the
  part that answers "is something wrong *right now*?" — the difference
  between a dashboard someone remembers to open and one that finds them.

  Every minute, each active client is measured over its own rolling
  window and put to three conditions:

    * **sentiment** — the mean has fallen to or below their threshold;
    * **volume** — mentions have reached a multiple of their own normal
      for this hour;
    * **watch phrases** — someone used a word they asked to hear about.

  The thresholds are per client (`SmmMonitor.Client.AlertConfig`), the
  judgement is pure (`SmmMonitor.Alerts.Conditions`), and this process
  holds only the clock, the incident state and the notifier fan-out.

  ## One alert per incident

  A condition that stays true is one problem, not sixty. Each is tracked
  as an `Incident`: opened the first time it trips, refreshed while it
  keeps tripping, and closed with an all-clear once it recovers. Exactly
  two messages reach the channel — *started* and *over, lasted 40 min* —
  which is the difference between a channel people read and one they
  mute.

  Clearing uses a margin rather than the trigger threshold, so a number
  sitting on the line doesn't alert and resolve alternately for an hour.

  ## Failure policy

  Alerting is the last thing that should be allowed to break collection.
  A failing notifier is logged and the others still run; a database that
  cannot answer means no baseline, which reads as "still warming up"
  rather than as a reason to alert.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Alerts.Conditions.{SentimentThreshold, VolumeSpike, WatchPhrase}
  alias SmmMonitor.Alerts.{Alert, Baseline, Incident}
  alias SmmMonitor.Alerts.Notifiers.{LogNotifier, SlackNotifier}
  alias SmmMonitor.Client.AlertConfig
  alias SmmMonitor.{Client, Clients, Monitor, Persistence}

  @evaluate_interval_ms :timer.minutes(1)
  @default_baseline_days 7
  # Keep enough for the dashboard to show a short history.
  @max_recent 50

  defmodule State do
    @moduledoc false
    defstruct interval_ms: nil,
              # %{key => Incident} of everything currently firing.
              incidents: %{},
              recent: [],
              evaluations: 0,
              raised: 0,
              resolved: 0,
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
  Alerts raised recently, newest first, optionally for one client.

  Read by the dashboard's banner. Returns `[]` if alerting isn't running,
  so callers never have to check first.
  """
  @spec recent(GenServer.server(), pos_integer(), String.t() | :all) :: [Alert.t()]
  def recent(server \\ __MODULE__, limit \\ 10, client \\ :all) do
    GenServer.call(server, {:recent, limit, client})
  catch
    :exit, _reason -> []
  end

  @doc "Incidents currently firing, for the dashboard and for tests."
  @spec active(GenServer.server(), String.t() | :all) :: [Incident.t()]
  def active(server \\ __MODULE__, client \\ :all) do
    GenServer.call(server, {:active, client})
  catch
    :exit, _reason -> []
  end

  @doc "Runs an evaluation immediately rather than waiting for the timer."
  @spec evaluate_now(GenServer.server()) :: {:ok, [Alert.t()]}
  def evaluate_now(server \\ __MODULE__), do: GenServer.call(server, :evaluate, 30_000)

  @doc "Counters, for tests and the dashboard."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc "Forgets all incidents and history. Test helper."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "The notifiers that are configured and will be called."
  @spec active_notifiers() :: [module()]
  def active_notifiers do
    :smm_monitor
    |> Application.get_env(:alert_notifiers, [LogNotifier, SlackNotifier])
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

  def handle_call({:recent, limit, client}, _from, state) do
    alerts =
      state.recent
      |> Enum.filter(&matches_client?(&1.client_id, client))
      |> Enum.take(limit)

    {:reply, alerts, state}
  end

  def handle_call({:active, client}, _from, state) do
    incidents =
      state.incidents
      |> Map.values()
      |> Enum.filter(&matches_client?(&1.alert.client_id, client))
      |> Enum.sort_by(& &1.opened_at, {:desc, DateTime})

    {:reply, incidents, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       evaluations: state.evaluations,
       raised: state.raised,
       resolved: state.resolved,
       last_evaluated_at: state.last_evaluated_at,
       active: Map.keys(state.incidents),
       notifiers: active_notifiers()
     }, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %State{interval_ms: state.interval_ms}}
  end

  # --- evaluation -----------------------------------------------------------

  defp run(state) do
    now = DateTime.utc_now()

    {alerts, state} =
      Enum.reduce(clients(), {[], state}, fn client, acc ->
        evaluate_client(client, now, acc)
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

  defp evaluate_client(%Client{} = client, now, acc) do
    config = client.alerts || AlertConfig.new()

    if AlertConfig.any_conditions?(config) do
      observation = observe(client, config, now)

      acc
      |> apply_verdict(client, config, observation, sentiment_verdict(observation, config), now)
      |> apply_verdict(client, config, observation, volume_verdict(observation, config), now)
      |> apply_phrase_verdicts(client, config, observation, now)
    else
      acc
    end
  end

  # One read of the window per client, shared by all three conditions:
  # they ask different questions of the same mentions, and reading three
  # times would be three times the work for the same answer.
  defp observe(%Client{id: client_id}, %AlertConfig{} = config, now) do
    stats = Monitor.stats(:all, config.window_ms, client_id)
    mentions = Monitor.recent(:all, 500, client_id)
    since = DateTime.add(now, -config.window_ms, :millisecond)
    in_window = Enum.filter(mentions, &(DateTime.compare(&1.timestamp, since) != :lt))

    %{
      client_id: client_id,
      average: stats.average,
      count: stats.count,
      negative: stats.negative,
      mentions: in_window,
      baseline: baseline(client_id, now)
    }
  end

  # The baseline comes from stored history rather than ETS: ETS holds a
  # rolling window measured in hours, which cannot say what a normal 9am
  # looks like.
  defp baseline(client_id, now) do
    days = SmmMonitor.config(:alert_baseline_days, @default_baseline_days)
    cutoff = DateTime.add(now, -(days + 1) * 24 * 3_600, :second)

    cutoff
    |> Persistence.timestamps_since(client: client_id)
    |> Baseline.same_hour(now, days)
  end

  defp sentiment_verdict(observation, config) do
    {SentimentThreshold, SentimentThreshold.evaluate(observation, config)}
  end

  defp volume_verdict(observation, config) do
    {VolumeSpike, VolumeSpike.evaluate(observation, config)}
  end

  defp apply_verdict({alerts, state}, client, config, observation, {module, verdict}, now) do
    case verdict do
      {:alert, details} ->
        raise_or_touch(details, client, config, {alerts, state}, now)

      {:ok, _reason} ->
        key = {client.id, module.kind(), nil}
        maybe_resolve(key, module, observation, config, {alerts, state}, now)
    end
  end

  # Watch phrases are the one condition that can raise several at once —
  # two different phrases are two different problems — so each gets its
  # own incident, and any phrase no longer present resolves.
  defp apply_phrase_verdicts({alerts, state}, client, config, observation, now) do
    verdicts = WatchPhrase.evaluate(observation, config)

    {alerts, state} =
      Enum.reduce(verdicts, {alerts, state}, fn
        {:alert, details}, acc -> raise_or_touch(details, client, config, acc, now)
        {:ok, _reason}, acc -> acc
      end)

    resolve_cleared_phrases({alerts, state}, client, config, observation, now)
  end

  defp resolve_cleared_phrases({alerts, state}, client, config, observation, now) do
    state.incidents
    |> Map.values()
    |> Enum.filter(&(&1.alert.client_id == client.id and &1.alert.kind == :watch_phrase))
    |> Enum.reduce({alerts, state}, fn incident, acc ->
      if WatchPhrase.cleared?(observation, config, incident.alert.subject) do
        resolve(incident, %{observed: 0}, acc, now)
      else
        acc
      end
    end)
  end

  defp raise_or_touch(details, client, config, {alerts, state}, now) do
    alert =
      Alert.firing(details, %{id: client.id, name: client.name},
        at: now,
        window_ms: config.window_ms
      )

    key = Alert.key(alert)

    case Map.get(state.incidents, key) do
      nil ->
        notify(alert)

        state = %{
          state
          | incidents: Map.put(state.incidents, key, Incident.open(alert)),
            recent: Enum.take([alert | state.recent], @max_recent),
            raised: state.raised + 1
        }

        {[alert | alerts], state}

      incident ->
        # Still true. Refresh the numbers so the dashboard shows a
        # worsening spike as worse, but say nothing to the channel.
        incidents = Map.put(state.incidents, key, Incident.touch(incident, alert))
        {alerts, %{state | incidents: incidents}}
    end
  end

  defp maybe_resolve(key, module, observation, config, {alerts, state}, now) do
    case Map.get(state.incidents, key) do
      nil ->
        {alerts, state}

      incident ->
        if module.cleared?(observation, config) do
          resolve(incident, recovery_details(module, observation), {alerts, state}, now)
        else
          # Below the trigger but not yet past the clearing margin: the
          # incident stays open rather than flapping.
          {alerts, state}
        end
    end
  end

  defp resolve(incident, recovery, {alerts, state}, now) do
    alert = Incident.close(incident, recovery, now)
    notify(alert)

    state = %{
      state
      | incidents: Map.delete(state.incidents, incident.key),
        recent: Enum.take([alert | state.recent], @max_recent),
        resolved: state.resolved + 1
    }

    {[alert | alerts], state}
  end

  defp recovery_details(SentimentThreshold, observation),
    do: %{observed: observation.average, count: observation.count}

  defp recovery_details(VolumeSpike, observation), do: %{observed: observation.count}
  defp recovery_details(_module, _observation), do: %{}

  # --- notifying ------------------------------------------------------------

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

  defp matches_client?(_client_id, :all), do: true
  defp matches_client?(client_id, client_id), do: true
  defp matches_client?(_client_id, _client), do: false
end
