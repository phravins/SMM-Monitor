defmodule SmmMonitor.Config do
  @moduledoc """
  Runtime-editable settings: the brand terms being tracked, and the
  subreddits Reddit watches.

  Everything else in the app is configured through `Application` env, which
  is the right home for settings fixed at boot — credentials, poll
  intervals, quota budgets. This GenServer exists for the settings a person
  changes *while the tool is running*, from the dashboard's config tab.
  Application env is not meant to be written to at runtime, so those live
  here instead.

  It is the single source of truth: fetchers read their search terms from
  here on every poll rather than from `Application.get_env/3`, which is
  what makes a change take effect on the next poll with no restart.

  ## Precedence

  On boot, values come from the persisted file if one exists, and from the
  compile-time/env-var defaults otherwise. A missing or unreadable file is
  not an error — it just means "no one has changed anything yet".

  ## Reads

  Reads are `GenServer.call/2`, not an ETS side-channel. The volume is
  tiny: once per poll per platform, plus once a second for the dashboard.
  The write path only touches a file of a few hundred bytes, so a read can
  never queue behind anything slow enough to matter.
  """

  use GenServer

  require Logger

  alias SmmMonitor.Config.Store

  @type t :: %{keywords: [String.t()], subreddits: [String.t()]}

  defmodule State do
    @moduledoc false
    defstruct keywords: [],
              subreddits: [],
              path: nil,
              # :defaults | :file | {:corrupt, reason}
              source: :defaults,
              updated_at: nil
  end

  # --- client ---------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The brand terms being tracked, searched for on every platform."
  @spec keywords(GenServer.server()) :: [String.t()]
  def keywords(server \\ __MODULE__), do: GenServer.call(server, :keywords)

  @doc "The subreddits Reddit watches. Empty means search all of Reddit."
  @spec subreddits(GenServer.server()) :: [String.t()]
  def subreddits(server \\ __MODULE__), do: GenServer.call(server, :subreddits)

  @doc "Everything editable, for the config screen."
  @spec all(GenServer.server()) :: t()
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @doc """
  Replaces the tracked brand terms.

  Accepts a list, or a comma-separated string as typed into the config
  screen. Returns `{:ok, keywords}`, or `{:error, reason}` if the input
  has no usable terms — monitoring nothing is never what someone meant.
  """
  @spec put_keywords(GenServer.server(), [String.t()] | String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def put_keywords(server \\ __MODULE__, keywords) do
    GenServer.call(server, {:put_keywords, keywords})
  end

  @doc """
  Replaces the watched subreddits.

  Accepts a list or a comma-separated string. An empty list is valid and
  means "search all of Reddit", so unlike keywords it is not rejected.
  """
  @spec put_subreddits(GenServer.server(), [String.t()] | String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def put_subreddits(server \\ __MODULE__, subreddits) do
    GenServer.call(server, {:put_subreddits, subreddits})
  end

  @doc "Where the settings are persisted."
  @spec path(GenServer.server()) :: Path.t()
  def path(server \\ __MODULE__), do: GenServer.call(server, :path)

  @doc """
  Where the current values came from: `:file`, `:defaults`, or
  `{:corrupt, reason}` when a file existed but could not be read.

  The config screen shows this, so a file that failed to load is visible
  rather than silently ignored.
  """
  @spec source(GenServer.server()) :: :file | :defaults | {:corrupt, term()}
  def source(server \\ __MODULE__), do: GenServer.call(server, :source)

  @doc "When the settings were last changed, or `nil` if never."
  @spec updated_at(GenServer.server()) :: DateTime.t() | nil
  def updated_at(server \\ __MODULE__), do: GenServer.call(server, :updated_at)

  @doc "Restores the compile-time defaults and persists them. Test helper."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc """
  Normalises user input into a clean list of terms.

  Accepts a list or a comma-separated string, trims whitespace, drops
  blanks and de-duplicates while preserving order.

      iex> SmmMonitor.Config.normalize("realoffice, real office")
      ["realoffice", "real office"]

      iex> SmmMonitor.Config.normalize(["  spaced  ", "", "spaced"])
      ["spaced"]
  """
  @spec normalize([String.t()] | String.t() | nil) :: [String.t()]
  def normalize(nil), do: []

  def normalize(value) when is_binary(value), do: value |> String.split(",") |> normalize()

  def normalize(values) when is_list(values) do
    values
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize(_value), do: []

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || Store.default_path()
    defaults = defaults(opts)

    state =
      case Store.load(path) do
        {:ok, stored} ->
          %State{
            keywords: pick(stored[:keywords], defaults.keywords),
            subreddits: pick(stored[:subreddits], defaults.subreddits),
            path: path,
            source: :file,
            updated_at: stored[:updated_at]
          }

        :missing ->
          %State{keywords: defaults.keywords, subreddits: defaults.subreddits, path: path}

        {:error, reason} ->
          # A broken file must never stop the app booting: fall back to the
          # defaults, keep the bad file for inspection, and say so loudly.
          Logger.warning(
            "config: could not read #{path} (#{inspect(reason)}); using defaults. " <>
              "The unreadable file has been kept alongside it with a .corrupt suffix."
          )

          Store.quarantine(path)

          %State{
            keywords: defaults.keywords,
            subreddits: defaults.subreddits,
            path: path,
            source: {:corrupt, reason}
          }
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:keywords, _from, state), do: {:reply, state.keywords, state}
  def handle_call(:subreddits, _from, state), do: {:reply, state.subreddits, state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}
  def handle_call(:source, _from, state), do: {:reply, state.source, state}
  def handle_call(:updated_at, _from, state), do: {:reply, state.updated_at, state}

  def handle_call(:all, _from, state) do
    {:reply, %{keywords: state.keywords, subreddits: state.subreddits}, state}
  end

  def handle_call({:put_keywords, input}, _from, state) do
    case normalize(input) do
      [] ->
        {:reply, {:error, :no_keywords}, state}

      keywords ->
        state = %{state | keywords: keywords}
        {:reply, {:ok, keywords}, persist(state)}
    end
  end

  def handle_call({:put_subreddits, input}, _from, state) do
    # An empty list is meaningful here: it searches all of Reddit.
    subreddits = normalize(input)
    state = %{state | subreddits: subreddits}
    {:reply, {:ok, subreddits}, persist(state)}
  end

  def handle_call(:reset, _from, state) do
    defaults = defaults([])

    state = %{
      state
      | keywords: defaults.keywords,
        subreddits: defaults.subreddits,
        source: :defaults
    }

    {:reply, :ok, persist(state)}
  end

  # --- internals ------------------------------------------------------------

  defp persist(state) do
    updated_at = DateTime.utc_now()

    case Store.save(state.path, %{
           keywords: state.keywords,
           subreddits: state.subreddits,
           updated_at: updated_at
         }) do
      :ok ->
        %{state | source: :file, updated_at: updated_at}

      {:error, reason} ->
        # The in-memory change still stands — losing it because the disk is
        # read-only would be worse than not persisting it.
        Logger.warning("config: could not write #{state.path} (#{inspect(reason)})")
        %{state | updated_at: updated_at}
    end
  end

  # Defaults come from the same Application env the rest of the app uses,
  # so an untouched install behaves exactly as its env vars say.
  defp defaults(opts) do
    %{
      keywords: normalize(Keyword.get(opts, :keywords) || SmmMonitor.config(:keywords, [])),
      subreddits: normalize(Keyword.get(opts, :subreddits) || configured_subreddits())
    }
  end

  defp configured_subreddits do
    :smm_monitor
    |> Application.get_env(SmmMonitor.Fetchers.Reddit, [])
    |> Keyword.get(:subreddits, [])
  end

  # A key absent from the file falls back to the default; a key present but
  # empty is respected (an empty subreddit list is a real choice).
  defp pick(nil, default), do: default
  defp pick(value, _default), do: value
end
