defmodule SmmMonitor.Reports.Scheduler do
  @moduledoc """
  Writes a weekly report for every active client, unprompted.

  A report someone has to remember to run is a report that stops being
  run. This checks once an hour whether the weekly slot has come round,
  and if it has, writes each active client's last seven days into the
  reports directory.

  ## Why an hourly check rather than a weekly timer

  A timer set for seven days assumes the process lives seven days. This
  one survives restarts, deploys and a machine that was asleep: it looks
  at the calendar rather than at elapsed time, and the record of what it
  has already done is the file on disk. Generating a report twice is
  harmless — it is the same period producing the same document — but
  it still checks, because a directory full of duplicates is noise.

  ## When

  Monday at 07:00 UTC by default: a week that ended last night, on
  somebody's desk before the Monday meeting. Configurable, because
  nobody else's Monday is the same as ours.

  Off by default. A process that writes files unprompted should be
  something you switched on.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Reports
  alias SmmMonitor.Reports.{Period, Writer}

  @check_interval_ms :timer.hours(1)
  @default_day 1
  @default_hour 7

  defmodule State do
    @moduledoc false
    defstruct check_interval_ms: nil, written: 0, last_run_at: nil, runs: 0
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether scheduled weekly reports are switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: SmmMonitor.config(:weekly_reports_enabled, false)

  @doc "Runs the weekly pass now, whatever the calendar says. For tests and operators."
  @spec run_now(GenServer.server()) :: {:ok, [Path.t()]}
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run, 120_000)

  @doc "Counters, for the dashboard and tests."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  Whether `now` falls in the weekly slot.

      iex> alias SmmMonitor.Reports.Scheduler
      iex> Scheduler.due?(~U[2026-09-14 07:30:00Z], day: 1, hour: 7)
      true
      iex> Scheduler.due?(~U[2026-09-14 09:30:00Z], day: 1, hour: 7)
      false
      iex> Scheduler.due?(~U[2026-09-15 07:30:00Z], day: 1, hour: 7)
      false
  """
  @spec due?(DateTime.t(), keyword()) :: boolean()
  def due?(now, opts \\ []) do
    day = Keyword.get(opts, :day, weekly_day())
    hour = Keyword.get(opts, :hour, weekly_hour())

    Date.day_of_week(DateTime.to_date(now)) == day and now.hour == hour
  end

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    unless Keyword.get(opts, :schedule?, true) == false do
      Process.send_after(self(), :check, Keyword.get(opts, :initial_delay_ms, :timer.minutes(2)))
    end

    {:ok, %State{check_interval_ms: interval}}
  end

  @impl true
  def handle_info(:check, state) do
    state = if due?(DateTime.utc_now()), do: elem(run(state), 1), else: state
    Process.send_after(self(), :check, state.check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {paths, state} = run(state)
    {:reply, {:ok, paths}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       enabled: enabled?(),
       runs: state.runs,
       written: state.written,
       last_run_at: state.last_run_at,
       directory: Writer.dir(),
       formats: Reports.available_formats()
     }, state}
  end

  # --- internals ------------------------------------------------------------

  defp run(state) do
    period = Period.last_days(7)
    clients = Reports.active_clients()

    paths =
      Enum.flat_map(clients, fn client ->
        case generate(client, period) do
          {:ok, paths} ->
            paths

          {:error, reason} ->
            # One client's report failing must not stop the others: a
            # weekly run that gives up on the first problem is a weekly
            # run that silently stops working.
            Logger.warning("reports: weekly report for #{client.id} failed (#{inspect(reason)})")
            []
        end
      end)

    if paths != [] do
      Logger.info("reports: wrote #{length(paths)} weekly report file(s) to #{Writer.dir()}")
    end

    {paths,
     %{
       state
       | runs: state.runs + 1,
         written: state.written + length(paths),
         last_run_at: DateTime.utc_now()
     }}
  end

  defp generate(client, period), do: Reports.generate(client, period: period)

  defp weekly_day, do: SmmMonitor.config(:weekly_report_day, @default_day)
  defp weekly_hour, do: SmmMonitor.config(:weekly_report_hour, @default_hour)
end
