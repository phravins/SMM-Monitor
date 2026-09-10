# The application starts with `start_fetchers: false` and `start_tui: false`
# (see config/test.exs), so tests get the processing layer and nothing else:
# no 30s polls racing assertions, no fight over the terminal.
ExUnit.start()

# The repo runs for the whole suite against a throwaway database (see
# config/test.exs). Migrations are applied once here rather than per test,
# and the sandbox gives each test its own transaction, rolled back at the
# end, so persistence tests can't see each other's rows.
if SmmMonitor.config(:start_persistence, true) do
  SmmMonitor.Persistence.Migrator.migrate(SmmMonitor.Repo)
  Ecto.Adapters.SQL.Sandbox.mode(SmmMonitor.Repo, :manual)
end
