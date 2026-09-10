defmodule SmmMonitor.Repo.Migrations.CreateClients do
  use Ecto.Migration

  def change do
    # The id is the slug rather than an integer: it is written onto every
    # mention row and read in log lines, where "acme-corp" beats "7".
    create table(:clients, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:keywords, :string, null: false)
      add(:subreddits, :string)
      add(:active, :boolean, default: true, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # The client list is read on every poll and rendered every second, and
    # a paused client must not cost anything to skip.
    create(index(:clients, [:active]))
  end
end
