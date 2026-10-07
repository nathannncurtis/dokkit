defmodule Dokkit.Repo.Migrations.AddImessageRuns do
  use Ecto.Migration

  def change do
    alter table(:task_runs) do
      add :payload, :map
      add :alert_id, references(:alerts, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:task_runs, [:alert_id], where: "alert_id IS NOT NULL")
  end
end
