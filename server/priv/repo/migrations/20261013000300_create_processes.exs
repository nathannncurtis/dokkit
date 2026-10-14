defmodule Dokkit.Repo.Migrations.CreateProcesses do
  use Ecto.Migration

  def change do
    create table(:process_lists, primary_key: false) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :at, :utc_datetime_usec, null: false
      add :total_memory_bytes, :bigint, null: false
      add :items, :jsonb, null: false
    end

    create table(:process_tops) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :text, null: false
      add :at, :utc_datetime_usec, null: false
      add :items, :jsonb, null: false
    end

    create index(:process_tops, [:machine_id, :kind, :at])
    create index(:process_tops, [:at])

    alter table(:issues) do
      add :processes, :jsonb
    end
  end
end
