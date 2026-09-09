defmodule SmmMonitor do
  @moduledoc """
  SMM Monitor — a terminal dashboard for tracking client brand mentions
  across social platforms.

  The system is three layers, each supervised independently:

    * **Fetching** — one GenServer per platform (`SmmMonitor.Fetchers.Worker`
      driving a `SmmMonitor.Fetchers.Fetcher` implementation), each under its
      own supervisor so a broken platform can't take the others down.
    * **Processing** — `SmmMonitor.Processing.Processor` owns an ETS table of
      recent mentions, scores sentiment, prunes old rows, and answers
      aggregate queries. `SmmMonitor.Monitor` is the public API over it.
    * **TUI** — `SmmMonitor.TUI.App`, a Ratatouille (Elm Architecture) app
      that polls the processing layer and renders the dashboard.

  Start the dashboard with `mix smm.tui`.
  """

  @doc "Config value for `:smm_monitor`, with a default."
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil), do: Application.get_env(:smm_monitor, key, default)

  @doc "The platforms configured for this instance, in display order."
  @spec platforms() :: [atom()]
  def platforms do
    :smm_monitor
    |> Application.get_env(:platforms, [])
    |> Enum.filter(fn {_platform, opts} -> Keyword.get(opts, :enabled, true) end)
    |> Enum.map(fn {platform, _opts} -> platform end)
  end
end
