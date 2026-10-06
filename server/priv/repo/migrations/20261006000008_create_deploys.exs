defmodule Dokkit.Repo.Migrations.CreateDeploys do
  use Ecto.Migration

  def change do
    create table(:deploys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :from, :text
      add :version, :text, null: false
      add :commit, :text
      add :by, :text
      add :how, :text, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create index(:deploys, [:service_id, :at])
  end
end
