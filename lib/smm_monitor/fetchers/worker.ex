defmodule SmmMonitor.Fetchers.Worker do
  @moduledoc """
  One polling GenServer per platform.

  The worker is the only process that knows about timers and failure
  handling; the platform module it drives is a pure `fetch(context)`
  function. Keeping it that way means the polling behaviour is written and
  debugged once for every platform we will ever add.

  Each poll:

    1. builds a `Fetcher.context` from config,
    2. calls `mock_fetch/1` or `fetch/1` depending on mode,
    3. hands the results to `SmmMonitor.Monitor`,
    4. schedules the next poll with `Process.send_after/3`.

  Scheduling happens *after* the work, not on a fixed interval, so a slow
  API can never let polls pile up on top of each other.

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
  alias SmmMonitor.Monitor

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
      poll_count: 0,
      mode: :mock,
      last_poll_at: nil,
      last_error: nil,
      inserted: 0,
      failures: 0
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

  @doc "Triggers a poll immediately, without waiting for the timer."
  @spec poll_now(atom()) :: :ok
  def poll_now(platform), do: GenServer.cast(name(platform), :poll)

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

    Process.send_after(self(), :poll, :rand.uniform(@startup_jitter_ms))

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_cast(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      platform: state.platform,
      display_name: state.module.display_name(),
      mode: state.mode,
      poll_count: state.poll_count,
      last_poll_at: state.last_poll_at,
      last_error: state.last_error,
      inserted: state.inserted,
      failures: state.failures,
      interval_ms: state.interval_ms
    }

    {:reply, status, state}
  end

  # --- internals ------------------------------------------------------------

  defp poll(state) do
    context = build_context(state)
    mode = mode(state.module, context)

    state =
      case do_fetch(state.module, mode, context) do
        {:ok, mentions} ->
          {:ok, %{inserted: inserted}} = Monitor.record_many(mentions)

          %{
            state
            | inserted: state.inserted + inserted,
              last_error: nil,
              last_poll_at: DateTime.utc_now()
          }

        {:error, reason} ->
          Logger.warning("#{state.platform} fetch failed: #{inspect(reason)}")

          %{
            state
            | failures: state.failures + 1,
              last_error: reason,
              last_poll_at: DateTime.utc_now()
          }
      end

    schedule_next(state.interval_ms)

    %{state | poll_count: state.poll_count + 1, mode: mode}
  end

  # Mock mode is a config flag, but a platform missing credentials also falls
  # back to fixtures: an unconfigured key should degrade one tab, not empty
  # the dashboard.
  defp mode(module, context) do
    cond do
      SmmMonitor.config(:mock_mode, true) -> :mock
      module.ready?(context) -> :live
      true -> :mock
    end
  end

  defp do_fetch(module, :mock, context), do: module.mock_fetch(context)
  defp do_fetch(module, :live, context), do: module.fetch(context)

  defp build_context(state) do
    %{
      platform: state.platform,
      keywords: SmmMonitor.config(:keywords, []),
      credentials: credentials(state.platform),
      opts: state.opts,
      poll_count: state.poll_count
    }
  end

  defp credentials(platform) do
    :smm_monitor
    |> Application.get_env(:credentials, [])
    |> Keyword.get(platform, [])
  end

  defp schedule_next(interval_ms), do: Process.send_after(self(), :poll, interval_ms)

  @doc false
  @spec context_for(module(), keyword()) :: Fetcher.context()
  def context_for(module, opts \\ []) do
    %{
      platform: module.platform(),
      keywords: SmmMonitor.config(:keywords, []),
      credentials: credentials(module.platform()),
      opts: opts,
      poll_count: 0
    }
  end
end
