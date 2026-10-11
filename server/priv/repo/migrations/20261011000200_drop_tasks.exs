defmodule Dokkit.Repo.Migrations.DropTasks do
  use Ecto.Migration

  def up do
    execute "DELETE FROM found WHERE kind = 'task'"

    execute """
    DELETE FROM task_runs USING tasks
    WHERE task_runs.task_id = tasks.id AND tasks.name NOT IN ('dokkit:update', 'dokkit:imessage')
    """

    alter table(:task_runs) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all)
      add :name, :text
    end

    execute """
    UPDATE task_runs SET machine_id = tasks.machine_id, name = tasks.name
    FROM tasks WHERE task_runs.task_id = tasks.id
    """

    alter table(:task_runs) do
      modify :machine_id, :binary_id, null: false
      modify :name, :text, null: false
      remove :task_id
    end

    drop table(:tasks)
    rename table(:task_runs), to: table(:work_runs)
    execute "ALTER INDEX task_runs_alert_id_index RENAME TO work_runs_alert_id_index"
    execute "ALTER INDEX task_runs_pkey RENAME TO work_runs_pkey"
    create index(:work_runs, [:machine_id, :state])
  end

  def down, do: raise(Ecto.MigrationError, "dropping tasks cannot be undone")
end
