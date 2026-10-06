defmodule Dokkit.Repo.Migrations.AddServiceSettings do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :watched, :boolean, null: false, default: true
      add :held, :text
      add :restart, :boolean, null: false, default: false
    end
  end
end
