defmodule SmmMonitor.Repo.Migrations.ScopeMentionsToClients do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  # Where mentions collected before this update end up. Named rather than
  # generated so the backfill and the boot-time seed agree without having
  # to pass anything between them.
  @legacy_client_id "unassigned"
  @legacy_client_name "Unassigned"

  def up do
    alter table(:mentions) do
      # Nullable for the length of this migration only: existing rows need
      # somewhere to land before the column can be relied on.
      add(:client_id, :string)
    end

    # SQLite needs the new column visible before it can be written to.
    flush()

    backfill_existing_mentions()

    # A post can match two clients' brand terms at once and is then two
    # mentions, one per client — so the natural key gains the client.
    # Without this the second client's copy would be rejected as a
    # duplicate of the first's.
    drop_if_exists(unique_index(:mentions, [:platform, :mention_id]))
    create(unique_index(:mentions, [:client_id, :platform, :mention_id]))

    # Every read is now scoped to a client, so every index should be too.
    create(index(:mentions, [:client_id, :platform, :source_timestamp]))
  end

  def down do
    drop_if_exists(index(:mentions, [:client_id, :platform, :source_timestamp]))
    drop_if_exists(unique_index(:mentions, [:client_id, :platform, :mention_id]))
    create(unique_index(:mentions, [:platform, :mention_id]))

    alter table(:mentions) do
      remove(:client_id)
    end
  end

  # Mentions collected before this update belong to whatever single brand
  # was being tracked at the time, but nothing in the row records which —
  # so they go to one holding client rather than being guessed at. The
  # boot-time seed renames it from the old keyword config where it can.
  defp backfill_existing_mentions do
    orphans = repo().one(from(m in "mentions", where: is_nil(m.client_id), select: count(m.id)))

    if orphans > 0 do
      now = DateTime.utc_now()

      repo().insert_all(
        "clients",
        [
          %{
            id: @legacy_client_id,
            name: @legacy_client_name,
            keywords: "",
            subreddits: "",
            active: true,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

      {updated, _returning} =
        repo().update_all(
          from(m in "mentions", where: is_nil(m.client_id)),
          set: [client_id: @legacy_client_id]
        )

      # Worth a line in the migration log: it tells the operator where
      # their existing history went, which is otherwise a mystery.
      IO.puts(
        "  scope_mentions_to_clients: assigned #{updated} existing mention(s) " <>
          "to the \"#{@legacy_client_name}\" client"
      )
    end
  end
end
