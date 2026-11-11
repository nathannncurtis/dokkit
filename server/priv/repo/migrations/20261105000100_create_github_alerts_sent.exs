defmodule Dokkit.Repo.Migrations.CreateGithubAlertsSent do
  use Ecto.Migration

  def change do
    create table(:github_alerts_sent, primary_key: false) do
      add :repo, :string, null: false
      add :number, :integer, null: false
      add :kind, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:github_alerts_sent, [:repo, :number, :kind])
  end
end
