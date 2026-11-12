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

  @doc """
  Turns invented data on for this run, for somebody who asked to look
  around without connecting an account.

  Demo data is off by default, so this is the only thing that switches
  it on from inside the app. It is deliberately loud in the interface:
  the header says DEMO DATA for as long as it is on.
  """
  @spec enable_demo_data() :: :ok
  def enable_demo_data do
    Application.put_env(:smm_monitor, :mock_mode, true)
    Application.put_env(:smm_monitor, :mock_platforms, [])
    :ok
  end

  @doc """
  Whether `platform` should serve fixture data instead of calling its API.

  `:mock_mode` is the global default; `:mock_platforms` overrides it per
  platform. Both are off unless demo data was asked for (`SMM_DEMO=1`, or
  the setup wizard's demo option).
  An entry of `nil` (an unset environment variable) means "inherit the
  global setting" rather than "live".
  """
  @spec mock_platform?(atom()) :: boolean()
  def mock_platform?(platform) do
    :smm_monitor
    |> Application.get_env(:mock_platforms, [])
    |> Keyword.get(platform)
    |> case do
      nil -> config(:mock_mode, false)
      value -> value
    end
  end

  @doc "The platforms configured for this instance, in display order."
  @spec platforms() :: [atom()]
  def platforms do
    :smm_monitor
    |> Application.get_env(:platforms, [])
    |> Enum.filter(fn {_platform, opts} -> Keyword.get(opts, :enabled, true) end)
    |> Enum.map(fn {platform, _opts} -> platform end)
  end
end
