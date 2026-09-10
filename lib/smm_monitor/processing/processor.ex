defmodule SmmMonitor.Processing.Processor do
  @moduledoc """
  The processing layer: a single GenServer that owns the mentions table.

  Its responsibilities are deliberately narrow:

    1. score incoming mentions (`SmmMonitor.Processing.Sentiment`),
    2. de-duplicate and store them (`SmmMonitor.Processing.Store`),
    3. hand the newly-stored ones to the durable log,
    4. keep lifetime counters per platform,
    5. prune the table on a timer.

  ETS remains the only read path. The database write is a cast to
  `SmmMonitor.Persistence.Writer` and nothing waits on it, so persistence
  is purely additive: it cannot slow a read, a poll, or a render.

  It does *not* fetch anything and it does *not* render anything. Reads are
  served straight from ETS by the caller (see `SmmMonitor.Monitor`), so this
  process only sits in the write path and never becomes a bottleneck for the
  TUI's refresh loop.

  Public callers should use `SmmMonitor.Monitor` rather than this module.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Mention
  alias SmmMonitor.Persistence
  alias SmmMonitor.Persistence.Writer
  alias SmmMonitor.Processing.{Sentiment, Store}

  @prune_interval_ms :timer.minutes(1)

  defmodule State do
    @moduledoc false
    defstruct [
      :table,
      # False in tests that assert on an empty database.
      persist?: true,
      # How many stored mentions were restored on boot.
      restored: 0,
      # %{platform => count} of everything ever ingested, including pruned rows.
      totals: %{},
      # Mentions rejected as already-seen. Useful signal when tuning polling.
      duplicates: 0,
      last_ingest_at: nil
    ]
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores mentions, scoring each one first.

  Synchronous on purpose: fetchers should feel backpressure rather than pile
  a poll's worth of work into a mailbox they never look at again.
  Returns `{:ok, %{inserted: n, duplicates: n}}`.
  """
  @spec ingest(GenServer.server(), [Mention.t() | map()]) ::
          {:ok, %{inserted: non_neg_integer(), duplicates: non_neg_integer()}}
  def ingest(server \\ __MODULE__, mentions) when is_list(mentions) do
    GenServer.call(server, {:ingest, mentions})
  end

  @doc "The ETS table mentions are stored in, for direct reads."
  @spec table(GenServer.server()) :: :ets.table()
  def table(server \\ __MODULE__), do: GenServer.call(server, :table)

  @doc "How many mentions were restored from the durable log on boot."
  @spec restored(GenServer.server()) :: non_neg_integer()
  def restored(server \\ __MODULE__), do: GenServer.call(server, :restored)

  @doc "Lifetime ingest counters, per platform."
  @spec totals(GenServer.server()) :: %{atom() => non_neg_integer()}
  def totals(server \\ __MODULE__), do: GenServer.call(server, :totals)

  @doc "Drops every stored mention and resets counters. Test helper."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "Runs a prune pass immediately instead of waiting for the timer."
  @spec prune_now(GenServer.server()) :: {:ok, non_neg_integer()}
  def prune_now(server \\ __MODULE__), do: GenServer.call(server, :prune)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, Store.table_name())
    table = Store.new(table_name)

    schedule_prune()

    # Restoring history reads from disk, so it happens after init returns
    # rather than holding up the supervision tree behind it.
    {:ok,
     %State{
       table: table,
       persist?: Keyword.get(opts, :persist?, SmmMonitor.config(:persist_writes, true))
     }, {:continue, {:load_history, opts}}}
  end

  @impl true
  def handle_continue({:load_history, opts}, state) do
    if Keyword.get(opts, :load_history?, SmmMonitor.config(:load_history_on_boot, true)) do
      {:noreply, load_history(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:ingest, mentions}, _from, state) do
    {state, result, stored} =
      Enum.reduce(mentions, {state, %{inserted: 0, duplicates: 0}, []}, fn raw,
                                                                           {state, result, stored} ->
        mention = raw |> normalize() |> score()

        case Store.insert(state.table, mention) do
          :inserted ->
            state = %{
              state
              | totals: Map.update(state.totals, mention.platform, 1, &(&1 + 1)),
                last_ingest_at: DateTime.utc_now()
            }

            {state, %{result | inserted: result.inserted + 1}, [mention | stored]}

          :duplicate ->
            state = %{state | duplicates: state.duplicates + 1}
            {state, %{result | duplicates: result.duplicates + 1}, stored}
        end
      end)

    # Fire-and-forget: ETS already has these, so the caller is not made to
    # wait on a disk write. Only newly-inserted mentions go across, so a
    # re-seen post costs nothing.
    persist(stored, state)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_call(:totals, _from, state), do: {:reply, state.totals, state}

  @impl true
  def handle_call(:restored, _from, state), do: {:reply, state.restored, state}

  @impl true
  def handle_call(:reset, _from, state) do
    Store.clear(state.table)
    {:reply, :ok, %State{table: state.table}}
  end

  @impl true
  def handle_call(:prune, _from, state) do
    {:reply, {:ok, do_prune(state)}, state}
  end

  @impl true
  def handle_info(:prune, state) do
    deleted = do_prune(state)
    if deleted > 0, do: Logger.debug("pruned #{deleted} mention(s)")

    schedule_prune()
    {:noreply, state}
  end

  # Unknown messages are logged rather than crashing the process that every
  # fetcher depends on.
  @impl true
  def handle_info(message, state) do
    Logger.debug("processor ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # --- internals ------------------------------------------------------------

  defp normalize(%Mention{} = mention), do: mention
  defp normalize(attrs), do: Mention.new(attrs)

  # Sentiment is computed once, on write, and stored on the struct. Reads are
  # then pure lookups — which is what makes a 1s TUI refresh cheap.
  defp score(%Mention{text: text} = mention) do
    {sentiment, score} = Sentiment.analyze(text)
    %{mention | sentiment: sentiment, sentiment_score: score}
  end

  defp do_prune(state) do
    retention = SmmMonitor.config(:retention_ms, :timer.hours(48))
    max = SmmMonitor.config(:max_mentions, 2_000)

    cutoff =
      DateTime.utc_now() |> DateTime.add(-retention, :millisecond) |> DateTime.to_unix(:millisecond)

    Store.prune(state.table, cutoff, max)
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)

  defp persist([], _state), do: :ok
  defp persist(_mentions, %State{persist?: false}), do: :ok
  defp persist(mentions, _state), do: Writer.store(Enum.reverse(mentions))

  # Puts the most recent stored mentions back into ETS so the dashboard
  # has history the moment it starts, instead of looking like a fresh
  # install until the first poll lands.
  defp load_history(state) do
    limit = SmmMonitor.config(:history_limit, 200)
    restored = SmmMonitor.platforms() |> Persistence.recent_by_platform(limit) |> insert_all(state)

    if restored > 0 do
      Logger.info("database: restored #{restored} mention(s) from previous runs")
    end

    %{state | restored: restored}
  end

  defp insert_all(mentions, state) do
    Enum.count(mentions, fn mention -> Store.insert(state.table, mention) == :inserted end)
  end
end
