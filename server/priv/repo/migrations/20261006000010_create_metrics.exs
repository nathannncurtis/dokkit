defmodule Dokkit.Repo.Migrations.CreateMetrics do
  use Ecto.Migration

  def change do
    create table(:metrics) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      add :name, :text, null: false
      add :value, :float, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create index(:metrics, [:service_id, :name, :at])
    create index(:metrics, [:machine_id, :name, :at])
    create index(:metrics, [:at])

    alter table(:services) do
      add :stats, :map
      add :stats_at, :utc_datetime_usec
    end
  end
end
