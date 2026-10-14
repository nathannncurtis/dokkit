defmodule Dokkit.Repo.Migrations.CreatePhones do
  use Ecto.Migration

  def change do
    create table(:phones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :slot, :text, null: false
      add :token_hash, :binary, null: false
      add :key, :binary, null: false
      add :last_fetch_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:phones, [:slot])
  end
end
