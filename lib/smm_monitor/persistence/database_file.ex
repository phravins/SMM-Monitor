defmodule SmmMonitor.Persistence.DatabaseFile do
  @moduledoc """
  Creates the database file and puts it in WAL mode before the connection
  pool opens.

  Without this, a *brand-new* database is a race: the pool opens several
  connections at once, each runs `PRAGMA journal_mode=WAL`, and that needs
  a brief exclusive lock. One of them loses and logs

      Exqlite.Connection failed to connect: database is locked

  It is not fatal — DBConnection retries and the schema is created — but
  it appears on roughly one fresh boot in four, and an error in the
  journal on a first install is exactly the wrong first impression.

  Once WAL is set it is recorded in the file header and persists, so the
  race only ever exists on the first boot. Doing it here, on a single
  direct connection before the pool exists, removes it entirely.

  Like `Persistence.Migrator`, this is a supervision-tree child that does
  its work in `start_link/1` and returns `:ignore`, leaving no process
  behind — the point is the ordering a supervisor gives us, not a process.
  """

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :temporary}
  end

  @doc """
  Prepares the database file, then returns `:ignore`.

  Failure is logged rather than raised: the repo will try anyway, and an
  unusable database should cost the operator their history, not their
  dashboard.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    case prepare(Keyword.get(opts, :database, database())) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("database: could not prepare file (#{inspect(reason)})")
    end

    :ignore
  end

  @doc """
  Creates the file if absent and sets the journal mode on a single
  connection. Safe to call when the file already exists.
  """
  @spec prepare(Path.t() | nil) :: :ok | {:error, term()}
  def prepare(nil), do: :ok

  def prepare(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Exqlite.Sqlite3.open(path) do
      try do
        Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL")
        :ok
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  rescue
    error -> {:error, error}
  end

  @doc "The configured database path, or nil if the repo isn't configured."
  @spec database() :: Path.t() | nil
  def database do
    :smm_monitor
    |> Application.get_env(SmmMonitor.Repo, [])
    |> Keyword.get(:database)
  end
end
