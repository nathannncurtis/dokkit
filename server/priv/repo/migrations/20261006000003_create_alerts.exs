defmodule Dokkit.Repo.Migrations.CreateAlerts do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    alter table(:services) do
      add :route_down, :text
      add :route_degraded, :text
    end

    create table(:alerts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :channel, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alerts, [:issue_id])
    create index(:alerts, [:status])
  end
end
