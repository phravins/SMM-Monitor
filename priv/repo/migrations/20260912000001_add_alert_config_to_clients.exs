defmodule SmmMonitor.Repo.Migrations.AddAlertConfigToClients do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      # A JSON blob rather than a column per setting: these are read
      # wholesale for one client and never queried across, so columns
      # would buy nothing and cost a migration every time a threshold is
      # added. Nullable — an existing client falls back to the defaults.
      add(:alert_config, :text)
    end
  end
end
