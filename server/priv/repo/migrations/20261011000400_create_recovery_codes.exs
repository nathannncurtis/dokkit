defmodule Dokkit.Repo.Migrations.CreateRecoveryCodes do
  use Ecto.Migration

  def change do
    create table(:recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :text, null: false
      add :used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:recovery_codes, [:user_id])
  end
end
