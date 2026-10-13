defmodule Dokkit.Repo.Migrations.CreateQuietSchedules do
  use Ecto.Migration

  def change do
    create table(:quiet_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repeat, :text, null: false
      add :at, :utc_datetime_usec
      add :time, :text
      add :days, {:array, :integer}, null: false, default: []
      add :seconds, :integer, null: false
      add :reason, :text
      add :by, :text, null: false
      add :last_started_on, :date
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:quiet_schedules, [:machine_id])

    alter table(:quiet_windows) do
      add :hold, :boolean, null: false, default: false
    end
  end
end
