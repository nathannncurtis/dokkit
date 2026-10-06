defmodule Dokkit.Repo.Migrations.CreateInstalls do
  use Ecto.Migration

  def change do
    create table(:installs, primary_key: false) do
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :version, :text, null: false
      add :seen_at, :utc_datetime_usec, null: false
    end
  end
end
