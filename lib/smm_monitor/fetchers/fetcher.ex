defmodule SmmMonitor.Fetchers.Fetcher do
  @moduledoc """
  The contract every platform module implements.

  A fetcher owns no processes and no timers: it is handed a context and its
  own state, and returns mentions plus the state to carry into the next
  poll. All the process machinery — polling, scheduling, error handling,
  handing results to the processing layer — lives once in
  `SmmMonitor.Fetchers.Worker`, so a new platform is just this behaviour
  plus a line of config.

  ## Per-platform state

  Most platforms need nothing between polls and can ignore the state
  argument entirely (`init_state/1` defaults to `nil`). Reddit is the
  reason it exists: it caches an OAuth token and its rate-limit quota
  there, so the token survives from one poll to the next and is refreshed
  only when it is close to expiring. The state lives in the worker's
  GenServer state, which means a crashing platform starts again with a
  clean token and cannot corrupt anyone else's.

  ## Adding a platform

      defmodule SmmMonitor.Fetchers.Mastodon do
        use SmmMonitor.Fetchers.Fetcher, platform: :mastodon

        @impl true
        def ready?(context), do: context.credentials[:access_token] != nil

        @impl true
        def fetch(context, state) do
          # ... call the API, map onto SmmMonitor.Mention.new/1 attrs ...
          {:ok, mentions, state}
        end
      end

  Then add it to `config :smm_monitor, :platforms` in `config/config.exs`.
  `use` provides a `mock_fetch/2` backed by the shared fixtures, so the new
  platform shows up in the dashboard before its API work is finished.
  """

  @typedoc """
  Everything a fetch needs, assembled by the worker on each poll.

    * `:platform`    — the platform atom
    * `:keywords`    — brand terms to search for
    * `:credentials` — from `config :smm_monitor, :credentials`
    * `:opts`        — the platform's `:opts` from config
    * `:poll_count`  — polls completed so far; 0 on the first one
    * `:interval_ms` — this platform's poll interval, so a fetcher working
      against a daily budget can tell whether its cadence is affordable
  """
  @type context :: %{
          platform: atom(),
          keywords: [String.t()],
          credentials: keyword(),
          opts: keyword(),
          poll_count: non_neg_integer(),
          interval_ms: pos_integer()
        }

  @typedoc "Whatever a platform needs to carry between polls. Often `nil`."
  @type state :: term()

  @typedoc "Mention attrs maps, as accepted by `SmmMonitor.Mention.new/1`."
  @type result :: {:ok, [map()], state()} | {:error, term(), state()}

  @doc "The platform this module fetches for."
  @callback platform() :: atom()

  @doc "Label shown in the TUI."
  @callback display_name() :: String.t()

  @doc """
  Whether a live fetch can be attempted: a real implementation exists *and*
  its credentials are configured. When this is false the worker falls back
  to mock data instead of failing, so a missing key degrades the dashboard
  rather than breaking it.
  """
  @callback ready?(context()) :: boolean()

  @doc "Initial per-platform state, built once when the worker starts."
  @callback init_state(context()) :: state()

  @doc "Fetches mentions from the live API."
  @callback fetch(context(), state()) :: result()

  @doc "Fetches fixture mentions. Defaults to the shared generator."
  @callback mock_fetch(context(), state()) :: result()

  @doc """
  How long to wait before the next poll, when an error asks for a delay.

  A fetcher signals this by failing with `{:rate_limited, ms}` (a
  short-term limit, as Reddit reports per minute) or `{:quota_exhausted,
  ms}` (a budget spent until it resets, as YouTube's daily quota works).
  The worker uses the delay instead of the usual interval. Anything else
  means "no opinion", and the normal schedule applies.
  """
  @spec retry_after(term()) :: pos_integer() | nil
  def retry_after({:rate_limited, ms}) when is_integer(ms) and ms > 0, do: ms
  def retry_after({:quota_exhausted, ms}) when is_integer(ms) and ms > 0, do: ms
  def retry_after(_reason), do: nil

  defmacro __using__(opts) do
    platform = Keyword.fetch!(opts, :platform)

    display_name =
      Keyword.get(opts, :display_name, platform |> Atom.to_string() |> String.capitalize())

    quote do
      @behaviour SmmMonitor.Fetchers.Fetcher

      @impl true
      def platform, do: unquote(platform)

      @impl true
      def display_name, do: unquote(display_name)

      # Conservative default: a platform is not live until it says so.
      @impl true
      def ready?(_context), do: false

      # Most platforms carry nothing between polls.
      @impl true
      def init_state(_context), do: nil

      # Conservative default: no live implementation yet.
      @impl true
      def fetch(_context, state), do: {:error, :not_implemented, state}

      @impl true
      def mock_fetch(context, state) do
        {:ok, mentions} = SmmMonitor.Fetchers.Fixtures.fetch(context)
        {:ok, mentions, state}
      end

      defoverridable ready?: 1, init_state: 1, fetch: 2, mock_fetch: 2, display_name: 0
    end
  end
end
