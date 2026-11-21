defmodule Dokkit.Repo.Migrations.CreateAppUpdates do
  use Ecto.Migration

  def change do
    create table(:app_releases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app, :string, null: false
      add :version, :string, null: false
      add :url, :string
      add :files, :map, null: false, default: %{}
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_releases, [:app, :version])

    create table(:app_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app, :string, null: false

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recipe, :map, null: false, default: %{}
      add :wanted_version, :string
      add :from_version, :string
      add :auto, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec
      add :asked_at, :utc_datetime_usec
      add :result_version, :string
      add :ok, :boolean
      add :note, :text
      add :result_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_targets, [:app, :machine_id])
  end
end
