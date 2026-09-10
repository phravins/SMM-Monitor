defmodule SmmMonitor.Repo do
  @moduledoc """
  The SQLite database holding collected mentions.

  ## Why Ecto rather than raw exqlite

  `ecto_sqlite3` uses `exqlite` as its driver, so this isn't a choice
  against exqlite — exqlite still does the work. What Ecto adds is worth
  the four extra dependencies here:

    * **Migrations.** The schema has to be created automatically on first
      boot, and evolve without a manual step later. `Ecto.Migrator` is
      versioned and idempotent; hand-rolling that on raw exqlite is fine
      until the second migration.
    * **Pooling.** Three separate processes touch the database — the
      writer, the boot loader and the retention job — and `DBConnection`
      makes that safe without a connection-owning GenServer of our own.

  Raw exqlite would be the better call for a single throwaway query. For
  a durable log with a schema that will change, this is the standard
  path.

  ## Durability settings

  WAL journalling and `synchronous = NORMAL` are set in `config.exs`. WAL
  lets the retention job delete rows while the writer is inserting, and
  `NORMAL` avoids an fsync per transaction — the right trade for a log of
  social mentions, where losing the last second of writes to a power cut
  costs nothing that the next poll won't re-fetch.
  """

  use Ecto.Repo,
    otp_app: :smm_monitor,
    adapter: Ecto.Adapters.SQLite3
end
