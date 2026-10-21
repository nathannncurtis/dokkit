defmodule Dokkit.Repo.Migrations.AddOncallToAlerts do
  use Ecto.Migration

  def change do
    alter table(:alerts) do
      add :oncall, :boolean, default: false, null: false
    end
  end
end
