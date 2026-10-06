defmodule Dokkit.Repo.Migrations.AddServiceNight do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :night, :boolean, null: false, default: true
    end
  end
end
