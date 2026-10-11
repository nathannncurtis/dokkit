defmodule Dokkit.Repo.Migrations.CreateAlertPeople do
  use Ecto.Migration

  def change do
    create table(:people, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :email, :text
      add :phone, :text
      add :imessage, :text
      add :ntfy_url, :text
      add :pushover_user, :text
      add :pagerduty_key, :text
      timestamps(type: :utc_datetime_usec)
    end

    create table(:alert_who, primary_key: false) do
      add :scope, :text, primary_key: true
      add :scope_id, :text, primary_key: true, default: ""
      add :people, {:array, :text}, null: false
    end

    create table(:alert_targets, primary_key: false) do
      add :alert_id, references(:alerts, type: :binary_id, on_delete: :delete_all), null: false
      add :person_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :opened, :boolean, null: false, default: false
      add :closed, :boolean, null: false, default: false
    end

    create unique_index(:alert_targets, [:alert_id, :person_id])
  end
end
