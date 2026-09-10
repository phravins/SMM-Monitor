defmodule SmmMonitor.Clients do
  @moduledoc """
  The clients being monitored: the runtime source of truth.

  This replaces the old single-brand config. Fetchers read
  the client list on every poll rather than at boot, which is what makes
  adding a client from the config screen take effect on the next poll
  with no restart — the same property the single-keyword config had.

  ## Where they live

  In SQLite, alongside the mentions, rather than in the old JSON config
  file. Mentions now reference a client, and keeping the two in separate
  stores would let a client vanish while its mentions still pointed at
  it. The GenServer holds a cached copy so that a read — once per poll
  per platform, plus once a second per dashboard — never waits on the
  database.

  ## What is *not* here

  Which client a viewer is currently looking at. That is per-session
  state and lives in the TUI model: two people on separate SSH sessions
  must be able to watch different clients without fighting over a shared
  selection.

  ## Failure policy

  Nothing here refuses to start. With persistence switched off, or a
  database that cannot be read, the list lives in memory for the
  lifetime of the process and every write is a warning rather than an
  error. Losing an edit to a read-only disk is bad; refusing to monitor
  anything because of one is worse.
  """

  use GenServer

  require Logger

  alias SmmMonitor.{Client, Mention}
  alias SmmMonitor.Clients.{Seed, Store}

  defmodule State do
    @moduledoc false
    # `source` records where the list came from, so the config screen can
    # say "these are in memory only" rather than implying they are saved.
    defstruct clients: [], source: :memory
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every client, oldest first."
  @spec list(GenServer.server()) :: [Client.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc """
  Clients that should be polled for: everything not paused.

  Fetchers use this rather than `list/1`, so pausing a client stops the
  API calls without touching its history.
  """
  @spec active(GenServer.server()) :: [Client.t()]
  def active(server \\ __MODULE__), do: GenServer.call(server, :active)

  @doc "One client by id, or `nil`."
  @spec get(GenServer.server(), String.t()) :: Client.t() | nil
  def get(server \\ __MODULE__, id), do: GenServer.call(server, {:get, id})

  @doc """
  Adds a client.

  The id is derived from the name and suffixed if it collides, because
  two clients called "Acme" is the operator's business and not something
  to refuse.
  """
  @spec add(GenServer.server(), map() | keyword()) :: {:ok, Client.t()} | {:error, atom()}
  def add(server \\ __MODULE__, attrs), do: GenServer.call(server, {:add, attrs})

  @doc "Applies a partial update. The id — and so the history — is kept."
  @spec update(GenServer.server(), String.t(), map() | keyword()) ::
          {:ok, Client.t()} | {:error, atom()}
  def update(server \\ __MODULE__, id, attrs), do: GenServer.call(server, {:update, id, attrs})

  @doc """
  Removes a client and everything collected for it.

  Returns `{:ok, mentions_deleted}`. Deleting is deliberately total: a
  client row left behind with no mentions, or mentions left behind with
  no client, are both states nothing else in the app knows how to
  render. Pause with `set_active/3` to stop polling without losing
  history.
  """
  @spec remove(GenServer.server(), String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def remove(server \\ __MODULE__, id), do: GenServer.call(server, {:remove, id})

  @doc "Pauses or resumes polling for a client, keeping its history."
  @spec set_active(GenServer.server(), String.t(), boolean()) ::
          {:ok, Client.t()} | {:error, atom()}
  def set_active(server \\ __MODULE__, id, active?) do
    update(server, id, %{active: active?})
  end

  @doc "Where the list came from: `:database` or `:memory`."
  @spec source(GenServer.server()) :: :database | :memory
  def source(server \\ __MODULE__), do: GenServer.call(server, :source)

  @doc """
  Replaces the whole list in memory, without touching the database.

  Test helper: it lets a test set up the exact book of clients it needs
  and put the previous one back afterwards, without writing rows that
  would outlive the test.
  """
  @spec replace(GenServer.server(), [Client.t()]) :: :ok
  def replace(server \\ __MODULE__, clients), do: GenServer.call(server, {:replace, clients})

  @doc "Re-reads from the database, discarding the cache. Test helper."
  @spec reload(GenServer.server()) :: [Client.t()]
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc """
  The id of the client a view should default to.

  The first active client, or the first of any, or the holding client's
  id when there are none at all — so a caller always has something to
  scope by.
  """
  @spec default_id(GenServer.server()) :: String.t()
  def default_id(server \\ __MODULE__) do
    case active(server) do
      [%Client{id: id} | _rest] ->
        id

      [] ->
        case list(server) do
          [%Client{id: id} | _rest] -> id
          [] -> Mention.default_client_id()
        end
    end
  end

  @doc """
  Every client id, for callers that read across the whole book — the
  boot-time history restore, mostly.
  """
  @spec ids(GenServer.server()) :: [String.t()]
  def ids(server \\ __MODULE__), do: server |> list() |> Enum.map(& &1.id)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo)

    {clients, source} =
      case Store.load(repo) do
        {:ok, []} ->
          # An empty table is a first boot: bring the old single-brand
          # config across so an upgrade doesn't silently stop monitoring.
          seeded = Seed.build(opts)
          Enum.each(seeded, &Store.insert(&1, repo))
          {seeded, :database}

        {:ok, clients} ->
          {clients, :database}

        {:error, reason} ->
          Logger.warning(
            "clients: could not read the clients table (#{inspect(reason)}); " <>
              "running from memory for this session. Changes will not be saved."
          )

          {Seed.build(opts), :memory}
      end

    log_startup(clients, source)

    {:ok, %State{clients: clients, source: source}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.clients, state}

  def handle_call(:active, _from, state) do
    {:reply, Enum.filter(state.clients, & &1.active), state}
  end

  def handle_call(:source, _from, state), do: {:reply, state.source, state}

  def handle_call({:get, id}, _from, state) do
    {:reply, Enum.find(state.clients, &(&1.id == id)), state}
  end

  def handle_call({:replace, clients}, _from, state) do
    {:reply, :ok, %{state | clients: clients}}
  end

  def handle_call(:reload, _from, state) do
    case Store.load(nil) do
      {:ok, clients} -> {:reply, clients, %{state | clients: clients, source: :database}}
      {:error, _reason} -> {:reply, state.clients, state}
    end
  end

  def handle_call({:add, attrs}, _from, state) do
    attrs = Map.new(attrs)
    name = attrs |> Map.get(:name) |> to_string() |> String.trim()

    case Client.new(Map.put(attrs, :id, unique_id(state, name))) do
      {:ok, client} ->
        persist(state, fn repo -> Store.insert(client, repo) end)
        {:reply, {:ok, client}, %{state | clients: state.clients ++ [client]}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case Enum.find(state.clients, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing ->
        case Client.update(existing, attrs) do
          {:ok, updated} ->
            persist(state, fn repo -> Store.upsert(updated, repo) end)
            clients = Enum.map(state.clients, &if(&1.id == id, do: updated, else: &1))
            {:reply, {:ok, updated}, %{state | clients: clients}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:remove, id}, _from, state) do
    if Enum.any?(state.clients, &(&1.id == id)) do
      deleted = Store.delete(id, nil)
      clients = Enum.reject(state.clients, &(&1.id == id))
      Logger.info("clients: removed #{id} and #{deleted} of its mention(s)")
      {:reply, {:ok, deleted}, %{state | clients: clients}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # --- internals ------------------------------------------------------------

  # A write that fails leaves the in-memory change standing: losing an
  # edit because the disk is read-only is worse than not saving it.
  defp persist(%State{source: :memory}, _fun), do: :ok

  defp persist(%State{}, fun) do
    case fun.(nil) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("clients: could not save the change (#{inspect(reason)})")
        :ok
    end
  end

  # "Acme" twice gives "acme" and "acme-2". Suffixing beats refusing: the
  # operator knows why they have two clients with the same name.
  defp unique_id(state, name) do
    base = Client.slug(name)
    taken = MapSet.new(state.clients, & &1.id)

    if MapSet.member?(taken, base) do
      Enum.find_value(2..1_000, "#{base}-#{System.unique_integer([:positive])}", fn n ->
        candidate = "#{base}-#{n}"
        unless MapSet.member?(taken, candidate), do: candidate
      end)
    else
      base
    end
  end

  defp log_startup([], source) do
    Logger.warning(
      "clients: no clients configured (#{source}); nothing will be polled for until " <>
        "one is added from the config screen"
    )
  end

  defp log_startup(clients, source) do
    names = Enum.map_join(clients, ", ", & &1.name)
    Logger.info("clients: monitoring #{length(clients)} client(s) from #{source}: #{names}")
  end
end
