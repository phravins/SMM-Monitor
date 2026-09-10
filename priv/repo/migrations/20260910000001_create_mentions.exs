defmodule SmmMonitor.Repo.Migrations.CreateMentions do
  use Ecto.Migration

  def change do
    create table(:mentions) do
      add(:mention_id, :string, null: false)
      add(:platform, :string, null: false)
      add(:author, :string)
      add(:text, :text)
      add(:url, :string)
      add(:source_timestamp, :utc_datetime_usec, null: false)
      add(:sentiment, :string)
      add(:sentiment_score, :integer)
      add(:mock, :boolean, default: false, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    # Ids are only unique *within* a platform, so the pair is the natural
    # key. This is what makes re-inserting after a restart a no-op rather
    # than a duplicate.
    create(unique_index(:mentions, [:platform, :mention_id]))

    # The boot load reads the most recent N for a platform, and retention
    # deletes everything older than a cutoff. Both walk this index.
    create(index(:mentions, [:platform, :source_timestamp]))
    create(index(:mentions, [:source_timestamp]))
  end
end
