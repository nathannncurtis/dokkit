defmodule Dokkit.Repo.Migrations.AddIssueNotes do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :notes, {:array, :map}, null: false, default: []
    end
  end
end
