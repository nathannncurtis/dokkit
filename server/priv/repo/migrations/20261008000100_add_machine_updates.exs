defmodule Dokkit.Repo.Migrations.AddMachineUpdates do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :server_version, :text
      add :updater_version, :text
      add :has_updater, :boolean, null: false, default: false
      add :hosts_server, :boolean, null: false, default: false
      add :wanted_version, :text
      add :update_version, :text
      add :update_ok, :boolean
      add :update_note, :text
      add :update_at, :utc_datetime_usec
    end
  end
end
