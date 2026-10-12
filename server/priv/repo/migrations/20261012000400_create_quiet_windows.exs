defmodule Dokkit.Repo.Migrations.CreateQuietWindows do
  use Ecto.Migration

  def change do
    create table(:quiet_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :started_at, :utc_datetime_usec, null: false
      add :until, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :silent_at, :utc_datetime_usec
      add :reason, :text
      add :by, :text, null: false
      add :ended_by, :text
    end

    create index(:quiet_windows, [:machine_id, :started_at])
  end
end
