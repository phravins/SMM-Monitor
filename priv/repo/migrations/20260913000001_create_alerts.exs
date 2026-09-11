defmodule SmmMonitor.Repo.Migrations.CreateAlerts do
  use Ecto.Migration

  def change do
    # Alerts lived only in the alerting process's memory, which meant a
    # restart forgot them and nothing outside that process could ever
    # read them — including reports, which is exactly where an alert
    # history belongs.
    create table(:alerts) do
      add(:client_id, :string)
      add(:kind, :string, null: false)
      # The watch phrase, for phrase alerts. Null for the rest.
      add(:subject, :string)
      # "firing" or "resolved" — both are stored, because "it ended" is
      # as much a part of the history as "it started".
      add(:state, :string, null: false)
      add(:severity, :string)
      add(:message, :text)
      add(:window_ms, :integer)
      add(:raised_at, :utc_datetime_usec, null: false)
      add(:opened_at, :utc_datetime_usec)
      add(:details, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    # Reports read one client's alerts over a date range, which is the
    # only query this table has.
    create(index(:alerts, [:client_id, :raised_at]))
    create(index(:alerts, [:raised_at]))
  end
end
