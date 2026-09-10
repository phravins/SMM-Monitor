defmodule SmmMonitor.Application do
  @moduledoc """
  Top of the supervision tree.

      SmmMonitor.Supervisor            (one_for_one)
      ├── SmmMonitor.Config                  — runtime-editable settings
      ├── SmmMonitor.Processing.Processor    — ETS owner + aggregation
      ├── SmmMonitor.Fetchers.Supervisor     — one child supervisor per platform
      │   ├── PlatformSupervisor(:reddit)    — Worker(:reddit)
      │   ├── PlatformSupervisor(:youtube)   — Worker(:youtube)
      │   └── ...
      └── Ratatouille.Runtime.Supervisor     — only when the TUI is enabled

  Order matters: `Config` starts first because the fetchers read their
  search terms from it, and the processor before the fetchers because it
  owns the ETS table they write into. The strategy is `:one_for_one` — a crashing
  platform supervisor is restarted on its own and never restarts the
  processor (which would drop every stored mention).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [SmmMonitor.Config, SmmMonitor.Processing.Processor] ++
        fetcher_children() ++
        tui_children()

    opts = [strategy: :one_for_one, name: SmmMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tests run with `start_fetchers: false` so they can feed the processing
  # layer deterministically instead of racing 30s polls.
  defp fetcher_children do
    if SmmMonitor.config(:start_fetchers, true) do
      [SmmMonitor.Fetchers.Supervisor]
    else
      []
    end
  end

  # The TUI grabs the terminal, so it is opt-in: `mix smm.tui`, the escript,
  # or `SMM_TUI=1 mix run --no-halt`.
  defp tui_children do
    if SmmMonitor.config(:start_tui, false) do
      [SmmMonitor.TUI.child_spec([])]
    else
      []
    end
  end
end
