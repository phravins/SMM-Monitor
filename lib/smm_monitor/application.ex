defmodule SmmMonitor.Application do
  @moduledoc """
  Top of the supervision tree.

      SmmMonitor.Supervisor            (one_for_one)
      ├── SmmMonitor.Config                  — runtime-editable settings
      ├── SmmMonitor.Repo                    — SQLite, the durable log
      ├── SmmMonitor.Persistence.Migrator    — migrates, then :ignore
      ├── SmmMonitor.Persistence.Writer      — off-critical-path writes
      ├── SmmMonitor.Persistence.Retention   — daily prune
      ├── SmmMonitor.Processing.Processor    — ETS owner + aggregation
      ├── SmmMonitor.Alerts                  — negative-sentiment spikes
      ├── SmmMonitor.SSH.Server              — remote dashboard, when enabled
      ├── SmmMonitor.Fetchers.Supervisor     — one child supervisor per platform
      │   ├── PlatformSupervisor(:reddit)    — Worker(:reddit)
      │   ├── PlatformSupervisor(:youtube)   — Worker(:youtube)
      │   └── ...
      └── Ratatouille.Runtime.Supervisor     — only when the TUI is enabled

  Order matters, and the supervisor's sequential startup is what enforces
  it: `Config` first because the fetchers read their search terms from it;
  then the repo, then the migrator, so the table exists before anything
  queries it; then the processor, which restores history on boot; then the
  fetchers that write into it.

  `Migrator` is a child that runs its work in `start_link/1` and returns
  `:ignore`, leaving no process behind. That is deliberate — a `Task`
  would return as soon as it was spawned, and the processor could start
  querying a table that did not exist yet. The strategy is `:one_for_one` — a crashing
  platform supervisor is restarted on its own and never restarts the
  processor (which would drop every stored mention).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [SmmMonitor.Config] ++
        persistence_children() ++
        [SmmMonitor.Processing.Processor] ++
        alert_children() ++
        ssh_children() ++
        fetcher_children() ++
        tui_children()

    opts = [strategy: :one_for_one, name: SmmMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Persistence is optional: with it off, the app is exactly what it was
  # before — an in-memory dashboard.
  defp persistence_children do
    if SmmMonitor.config(:start_persistence, true) do
      [SmmMonitor.Repo, SmmMonitor.Persistence.Migrator] ++ writer_children()
    else
      []
    end
  end

  # Tests keep the repo (so they have a database to assert against) but
  # start their own writer inside the sandbox, rather than having a
  # long-lived one writing outside any test's ownership.
  defp writer_children do
    if SmmMonitor.config(:persist_writes, true) do
      [SmmMonitor.Persistence.Writer, SmmMonitor.Persistence.Retention]
    else
      []
    end
  end

  # Alerting needs the processor (for the current window) and the repo
  # (for the baseline), so it starts after both.
  defp alert_children do
    if SmmMonitor.Alerts.enabled?() do
      [SmmMonitor.Alerts]
    else
      []
    end
  end

  # Off unless asked for: a dashboard that starts listening on a port
  # because someone upgraded is not a pleasant surprise.
  defp ssh_children do
    if SmmMonitor.SSH.Server.enabled?() do
      [SmmMonitor.SSH.Server]
    else
      []
    end
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
