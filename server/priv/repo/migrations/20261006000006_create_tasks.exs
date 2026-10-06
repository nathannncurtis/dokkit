defmodule Dokkit.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :command, :text, null: false
      add :accepted, :text
      add :dismissed, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:machine_id, :name])

    create table(:task_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :state, :text, null: false, default: "queued"
      add :by, :text
      add :exit_code, :integer
      add :duration_ms, :bigint
      add :output, :text, null: false, default: ""
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:task_runs, [:task_id, :inserted_at])
  end
end
