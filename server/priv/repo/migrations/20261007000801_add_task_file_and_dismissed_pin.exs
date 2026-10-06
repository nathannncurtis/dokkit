defmodule Dokkit.Repo.Migrations.AddTaskFileAndDismissedPin do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :file, :text
      add :dismissed_pin, :text
    end
  end
end
