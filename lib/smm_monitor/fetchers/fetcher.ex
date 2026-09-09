defmodule SmmMonitor.Fetchers.Fetcher do
  @moduledoc """
  The contract every platform module implements.

  A fetcher is stateless: it is handed a context and returns mentions.
  All the process machinery — polling, scheduling, error handling, handing
  results to the processing layer — lives once in
  `SmmMonitor.Fetchers.Worker`, so a new platform is just this behaviour
  plus a line of config.

  ## Adding a platform

      defmodule SmmMonitor.Fetchers.Mastodon do
        use SmmMonitor.Fetchers.Fetcher, platform: :mastodon

        @impl true
        def ready?(context), do: context.credentials[:access_token] != nil

        @impl true
        def fetch(context) do
          # ... call the API, map onto SmmMonitor.Mention.new/1 attrs ...
          {:ok, mentions}
        end
      end

  Then add it to `config :smm_monitor, :platforms` in `config/config.exs`.
  `use` provides a `mock_fetch/1` backed by the shared fixtures, so the new
  platform shows up in the dashboard before its API work is finished.
  """

  @typedoc """
  Everything a fetch needs, assembled by the worker on each poll.

    * `:platform`    — the platform atom
    * `:keywords`    — brand terms to search for
    * `:credentials` — from `config :smm_monitor, :credentials`
    * `:opts`        — the platform's `:opts` from config
    * `:poll_count`  — polls completed so far; 0 on the first one
  """
  @type context :: %{
          platform: atom(),
          keywords: [String.t()],
          credentials: keyword(),
          opts: keyword(),
          poll_count: non_neg_integer()
        }

  @typedoc "Mention attrs maps, as accepted by `SmmMonitor.Mention.new/1`."
  @type result :: {:ok, [map()]} | {:error, term()}

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

  @doc "Fetches mentions from the live API."
  @callback fetch(context()) :: result()

  @doc "Fetches fixture mentions. Defaults to the shared generator."
  @callback mock_fetch(context()) :: result()

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

      # Conservative default: no live implementation yet.
      @impl true
      def fetch(_context), do: {:error, :not_implemented}

      @impl true
      def mock_fetch(context), do: SmmMonitor.Fetchers.Fixtures.fetch(context)

      defoverridable ready?: 1, fetch: 1, mock_fetch: 1, display_name: 0
    end
  end
end
