defmodule Dokkit.Repo.Migrations.AddUpdateRunToMachines do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :update_started_at, :utc_datetime_usec
      add :update_asked_at, :utc_datetime_usec
    end
  end
end
