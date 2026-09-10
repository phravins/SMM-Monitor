defmodule SmmMonitor.Repo.Migrations.AddSentimentValue do
  use Ecto.Migration

  def change do
    # Nullable and additive: existing rows keep their integer score and
    # their label, and MentionRecord derives a value for them on read.
    # Backfilling by rescoring would rewrite what past mentions "meant"
    # every time the word lists were tuned.
    alter table(:mentions) do
      add(:sentiment_value, :float)
    end
  end
end
