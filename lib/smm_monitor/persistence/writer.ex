defmodule SmmMonitor.Persistence.Writer do
  @moduledoc """
  Writes mentions to the durable log, off the critical path.

  The processing layer hands work over with `GenServer.cast/2` and carries
  on immediately, so a slow disk can never stall a fetcher's poll or the
  dashboard's refresh. If writes fall behind, they queue in this process's
  mailbox rather than anywhere that would be noticed.

  A whole poll's mentions arrive as one message and go in as one
  statement, so batching comes for free without a flush timer or the
  durability window one would introduce.

  A failed write is logged and dropped. The alternative — retrying, or
  crashing — would trade a gap in history for a stalled dashboard, and
  the dashboard is the part someone is looking at.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Persistence

  defmodule State do
    @moduledoc false
    defstruct written: 0, failures: 0, last_error: nil, last_write_at: nil
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Queues mentions to be written. Returns immediately.

  Fire-and-forget by design: the caller has already put these in ETS, so
  the dashboard is up to date whether or not the disk keeps up.
  """
  @spec store(GenServer.server(), [SmmMonitor.Mention.t()]) :: :ok
  def store(server \\ __MODULE__, mentions)
  def store(_server, []), do: :ok
  def store(server, mentions), do: GenServer.cast(server, {:store, mentions})

  @doc "Write counters, for tests and the dashboard."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  Blocks until everything queued so far has been written.

  Only for tests: a `call` behind the queued casts returns once they have
  been processed. Nothing in the running app needs this.
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :flush, timeout)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts), do: {:ok, %State{}, {:continue, {:configure, opts}}}

  @impl true
  def handle_continue({:configure, _opts}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:store, mentions}, state) do
    case Persistence.store(mentions) do
      {:ok, count} ->
        {:noreply, %{state | written: state.written + count, last_write_at: DateTime.utc_now()}}

      {:error, reason} ->
        # Logged once per failure rather than per mention; history has a
        # gap, but the dashboard and fetchers are unaffected.
        Logger.warning(
          "database: could not store #{length(mentions)} mention(s): #{inspect(reason)}"
        )

        {:noreply, %{state | failures: state.failures + 1, last_error: reason}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       written: state.written,
       failures: state.failures,
       last_error: state.last_error,
       last_write_at: state.last_write_at
     }, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}
end
