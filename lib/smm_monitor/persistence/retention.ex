defmodule SmmMonitor.Persistence.Retention do
  @moduledoc """
  Deletes mentions older than the configured window, once a day.

  Without this the database is an append-only log that grows forever. The
  window defaults to 30 days (`SMM_RETENTION_DAYS`), which keeps the file
  small enough to ignore while still covering a monthly reporting cycle.

  The first pass runs shortly after boot rather than a day later, so a
  long-stopped instance tidies up as soon as it comes back rather than
  carrying a year of stale rows until its first anniversary.

  Retention is keyed on when a mention was *published*, not when we stored
  it, so backfilling old history doesn't earn it another 30 days.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Persistence

  @interval_ms :timer.hours(24)
  # Late enough not to compete with the boot load for the connection pool.
  @initial_delay_ms :timer.seconds(30)

  defmodule State do
    @moduledoc false
    defstruct deleted: 0, runs: 0, last_run_at: nil, interval_ms: nil
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs a prune immediately rather than waiting for the timer."
  @spec prune_now(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_now(server \\ __MODULE__), do: GenServer.call(server, :prune, 30_000)

  @doc "Retention counters, for tests and the dashboard."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  The cutoff for a given retention window.

  `now` is injectable so pruning can be tested without waiting days.

      iex> alias SmmMonitor.Persistence.Retention
      iex> Retention.cutoff(30, ~U[2026-03-31 12:00:00Z])
      ~U[2026-03-01 12:00:00Z]
  """
  @spec cutoff(pos_integer(), DateTime.t()) :: DateTime.t()
  def cutoff(retention_days, now \\ DateTime.utc_now()) do
    DateTime.add(now, -retention_days * 24 * 3_600, :second)
  end

  @doc "The configured retention window in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: SmmMonitor.config(:db_retention_days, 30)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)

    unless Keyword.get(opts, :schedule?, true) == false do
      Process.send_after(self(), :prune, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    end

    {:ok, %State{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:prune, state) do
    state = run_prune(state)
    Process.send_after(self(), :prune, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:prune, _from, state) do
    state = run_prune(state)
    {:reply, {:ok, state.deleted}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       deleted: state.deleted,
       runs: state.runs,
       last_run_at: state.last_run_at,
       retention_days: retention_days()
     }, state}
  end

  # --- internals ------------------------------------------------------------

  defp run_prune(state) do
    days = retention_days()

    case Persistence.prune(cutoff(days, DateTime.utc_now())) do
      {:ok, 0} ->
        %{state | runs: state.runs + 1, last_run_at: DateTime.utc_now()}

      {:ok, count} ->
        Logger.info("database: pruned #{count} mention(s) older than #{days} days")

        %{
          state
          | deleted: state.deleted + count,
            runs: state.runs + 1,
            last_run_at: DateTime.utc_now()
        }

      {:error, reason} ->
        # A failed prune is not worth crashing over; it retries tomorrow.
        Logger.warning("database: prune failed (#{inspect(reason)})")
        %{state | runs: state.runs + 1, last_run_at: DateTime.utc_now()}
    end
  end
end
