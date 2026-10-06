defmodule Dokkit.Repo.Migrations.WidenExitCodesAndBatchKey do
  use Ecto.Migration

  def up do
    alter table(:job_runs), do: modify(:exit_code, :bigint)
    alter table(:task_runs), do: modify(:exit_code, :bigint)
    execute "ALTER TABLE batches DROP CONSTRAINT batches_pkey"
    execute "ALTER TABLE batches ADD PRIMARY KEY (id, key_id)"
  end

  def down do
    execute "ALTER TABLE batches DROP CONSTRAINT batches_pkey"
    execute "ALTER TABLE batches ADD PRIMARY KEY (id)"
    alter table(:task_runs), do: modify(:exit_code, :integer)
    alter table(:job_runs), do: modify(:exit_code, :integer)
  end
end
