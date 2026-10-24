defmodule Dokkit.Repo.Migrations.AddDeployer do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :deployer, :boolean, default: false, null: false
    end

    alter table(:deploys) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
