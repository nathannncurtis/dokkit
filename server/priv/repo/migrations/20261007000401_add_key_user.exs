defmodule Dokkit.Repo.Migrations.AddKeyUser do
  use Ecto.Migration

  def change do
    alter table(:keys) do
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
