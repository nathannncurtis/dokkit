defmodule Dokkit.Repo.Migrations.CreateFound do
  use Ecto.Migration

  def change do
    create table(:found, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :text, null: false
      add :key, :text, null: false
      add :detail, :map, null: false, default: %{}
      add :dismissed, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:found, [:machine_id, :kind, :key])
  end
end
