defmodule Dokkit.Repo.Migrations.AddIssueSoon do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :soon, :boolean, null: false, default: false
    end
  end
end
