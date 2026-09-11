defmodule SmmMonitor.Repo.Migrations.IndexMentionsByClientAndDay do
  use Ecto.Migration

  # The trends screen asks for one client's mentions between two dates,
  # across every platform. The index from the multi-client migration is
  # (client_id, platform, source_timestamp), and SQLite can only use a
  # prefix of it: with no platform in the query it matches on client_id
  # and then scans every row that client has ever collected, checking the
  # dates one by one. That is fine in a fortnight-old database and
  # steadily worse in a year-old one — which is exactly the screen that
  # must not get slower as history accumulates.
  #
  # With the pair in index order the database seeks straight to the start
  # of the window and walks only the days being drawn, so the cost tracks
  # the window rather than the history behind it.
  def change do
    create(index(:mentions, [:client_id, :source_timestamp]))
  end
end
