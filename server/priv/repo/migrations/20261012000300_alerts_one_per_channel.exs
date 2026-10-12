defmodule Dokkit.Repo.Migrations.AlertsOnePerChannel do
  use Ecto.Migration

  def change do
    drop unique_index(:alerts, [:issue_id])
    create unique_index(:alerts, [:issue_id, :channel])
  end
end
