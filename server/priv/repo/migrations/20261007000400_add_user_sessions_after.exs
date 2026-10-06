defmodule Dokkit.Repo.Migrations.AddUserSessionsAfter do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :sessions_after, :bigint, null: false, default: 0
    end
  end
end
