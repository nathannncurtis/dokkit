defmodule Dokkit.Repo.Migrations.CreateCore do
  use Ecto.Migration

  def change do
    create table(:machines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :kind, :text, null: false, default: "enrolled"
      add :os, :text
      add :arch, :text
      add :program_version, :text
      add :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:machines, [:name])

    create table(:services, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :slug, :text, null: false
      add :name, :text, null: false
      add :kind, :text, null: false, default: "service"
      add :environment, :text, null: false, default: "production"
      add :version, :text
      add :listens, :text
      add :watched, :boolean, null: false, default: true
      add :state, :text, null: false, default: "unknown"
      add :note, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:services, [:machine_id, :slug])

    create table(:checks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :type, :text, null: false
      add :source, :text, null: false, default: "interface"
      add :config, :map, null: false, default: %{}
      add :fail_after, :integer, null: false, default: 3
      add :state, :text, null: false, default: "unknown"
      add :fails, :integer, null: false, default: 0
      add :passes, :integer, null: false, default: 0
      add :value, :float
      add :note, :text
      add :checked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:checks, [:service_id, :name])

    create table(:issues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :number, :bigserial, null: false

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      add :check_id, references(:checks, type: :binary_id, on_delete: :delete_all)
      add :kind, :text, null: false
      add :state, :text, null: false
      add :title, :text, null: false
      add :count, :integer, null: false, default: 1
      add :since, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :snoozed_until, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issues, [:number])
    create index(:issues, [:check_id, :closed_at])

    create unique_index(:issues, [:check_id],
             where: "closed_at IS NULL",
             name: :issues_one_open_per_check
           )

    create table(:keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :text, null: false
      add :hash, :binary, null: false
      add :hint, :text, null: false
      add :label, :text
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all)
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      add :scopes, {:array, :text}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:keys, [:hash])

    create table(:job_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :check_id, references(:checks, type: :binary_id, on_delete: :delete_all), null: false
      add :run, :text, null: false
      add :result, :text, null: false, default: "running"
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :exit_code, :integer
      add :duration_ms, :bigint
      add :done, :bigint
      add :total, :bigint
      add :tail, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:job_runs, [:check_id, :run])
    create index(:job_runs, [:check_id, :started_at])

    create table(:batches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key_id, references(:keys, type: :binary_id, on_delete: :delete_all), null: false
      add :accepted, :integer, null: false
      add :refused, {:array, :map}, null: false, default: []
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
