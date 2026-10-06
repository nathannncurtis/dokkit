defmodule Dokkit.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :password_hash, :text, null: false
      add :role, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, ["lower(name)"])
  end
end
