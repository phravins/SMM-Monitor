defmodule SmmMonitor.Persistence.Migrator do
  @moduledoc """
  Runs pending migrations during startup, so there is no manual setup
  step before running the app.

  This is a supervision-tree child that never leaves a process behind:
  `start_link/1` does the work and returns `:ignore`, which a supervisor
  treats as "nothing to supervise, carry on". The point is the *timing* —
  a supervisor waits for each child's `start_link` to return before
  starting the next, so placing this after the repo and before anything
  that reads guarantees the table exists by the time the boot load runs.
  A `Task` would not give that guarantee, since its `start_link` returns
  as soon as the process is spawned.
  """

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :temporary}
  end

  @doc """
  Migrates the repo up to the latest version, then returns `:ignore`.

  A migration failure is logged rather than raised: an unusable database
  should cost the operator their history, not their dashboard. The
  fetchers and TUI run perfectly well without persistence.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    repo = Keyword.get(opts, :repo, SmmMonitor.Repo)

    case migrate(repo) do
      {:ok, []} -> :ok
      {:ok, versions} -> Logger.info("database: applied #{length(versions)} migration(s)")
      {:error, reason} -> Logger.warning("database: migration failed (#{inspect(reason)})")
    end

    :ignore
  end

  @doc "Runs migrations, returning the versions applied."
  @spec migrate(module()) :: {:ok, [integer()]} | {:error, term()}
  def migrate(repo \\ SmmMonitor.Repo) do
    # Ecto.Migrator.run/4 returns a bare list of applied versions, not an
    # {:ok, _} tuple.
    versions = Ecto.Migrator.run(repo, migrations_path(), :up, all: true)
    {:ok, versions}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Where the migration files live."
  @spec migrations_path() :: String.t()
  def migrations_path do
    priv = :code.priv_dir(:smm_monitor) |> to_string()
    Path.join([priv, "repo", "migrations"])
  end
end
