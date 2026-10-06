defmodule Dokkit.Repo.Migrations.CreateErrors do
  use Ecto.Migration

  def change do
    create table(:error_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :fingerprint, :text, null: false
      add :type, :text, null: false
      add :top, :text
      add :count, :bigint, null: false, default: 0
      add :first_seen, :utc_datetime_usec, null: false
      add :last_seen, :utc_datetime_usec, null: false
      add :release, :text
      add :host, :text
      add :handled, :boolean, null: false, default: false
    end

    create unique_index(:error_groups, [:service_id, :fingerprint])

    create table(:error_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:error_groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :at, :utc_datetime_usec, null: false
      add :release, :text
      add :host, :text
      add :handled, :boolean, null: false, default: false
      add :frames, {:array, :map}, null: false, default: []
      add :tags, :map, null: false, default: %{}
    end

    create index(:error_events, [:group_id, :at])
  end
end
