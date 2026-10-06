defmodule Dokkit.Repo.Migrations.AddMachineSeenBy do
  use Ecto.Migration

  def change do
    alter table(:machines) do
      add :seen_by, references(:keys, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:machines, [:seen_by], where: "seen_by IS NOT NULL")
  end
end
