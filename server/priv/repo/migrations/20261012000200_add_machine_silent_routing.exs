defmodule Dokkit.Repo.Migrations.AddMachineSilentRouting do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :silent_route, :text
      add :silent_wake, :boolean, null: false, default: true
    end
  end
end
