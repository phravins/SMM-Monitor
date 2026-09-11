defmodule SmmMonitor.Application do
  @moduledoc """
  Top of the supervision tree.

      SmmMonitor.Supervisor            (one_for_one)
      ├── SmmMonitor.Persistence.DatabaseFile — creates the file, then :ignore
      ├── SmmMonitor.Repo                    — SQLite, the durable log
      ├── SmmMonitor.Persistence.Migrator    — migrates, then :ignore
      ├── SmmMonitor.Persistence.Writer      — off-critical-path writes
      ├── SmmMonitor.Persistence.Retention   — daily prune
      ├── SmmMonitor.Clients                 — the clients being monitored
      ├── SmmMonitor.Processing.Processor    — ETS owner + aggregation
      ├── SmmMonitor.Alerts                  — sentiment, volume and phrases
      ├── SmmMonitor.Reports.Scheduler       — weekly client reports, when enabled
      ├── SmmMonitor.SSH.Server              — remote dashboard, when enabled
      ├── SmmMonitor.Fetchers.Supervisor     — one child supervisor per platform
      │   ├── PlatformSupervisor(:reddit)    — Worker(:reddit)
      │   ├── PlatformSupervisor(:youtube)   — Worker(:youtube)
      │   └── ...
      └── Ratatouille.Runtime.Supervisor     — only when the TUI is enabled

  Order matters, and the supervisor's sequential startup is what enforces
  it: the repo and then the migrator, so the tables exist before anything
  queries them; then `Clients`, which reads the clients table and seeds it
  from the old single-brand config on an upgrade; then the processor,
  which restores each client's history on boot; then the fetchers, which
  read the client list on every poll and write into the processor.

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
      persistence_children() ++
        [SmmMonitor.Clients] ++
        [SmmMonitor.Processing.Processor] ++
        alert_children() ++
        report_children() ++
        ssh_children() ++
        fetcher_children() ++
        tui_children()

    opts = [strategy: :one_for_one, name: SmmMonitor.Supervisor]

    # Only does anything in the downloaded binary, where the node would
    # otherwise halt the moment boot finishes. See SmmMonitor.Standalone.
    SmmMonitor.Standalone.hold_open()

    Supervisor.start_link(children, opts)
  end

  # Persistence is optional: with it off, the app is exactly what it was
  # before — an in-memory dashboard.
  defp persistence_children do
    if SmmMonitor.config(:start_persistence, true) do
      [
        # Before the repo: puts a brand-new file into WAL mode on one
        # connection, so the pool's connections don't race to do it.
        SmmMonitor.Persistence.DatabaseFile,
        SmmMonitor.Repo,
        SmmMonitor.Persistence.Migrator
      ] ++ writer_children()
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

  # Weekly reports read the durable log and write files, so they start
  # after persistence. Off by default: a process that writes files
  # unprompted should be something you switched on.
  defp report_children do
    if SmmMonitor.Reports.Scheduler.enabled?() do
      [SmmMonitor.Reports.Scheduler]
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
