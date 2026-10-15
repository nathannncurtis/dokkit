defmodule Dokkit.Repo.Migrations.AddUpdaterCheckedAtToMachines do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :updater_checked_at, :utc_datetime_usec
    end
  end
end
