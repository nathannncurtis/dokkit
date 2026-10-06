defmodule Dokkit.Repo.Migrations.AddTaskPins do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :pin, :text
      add :accepted_pin, :text
    end

    # Dokkit's own update task is not declared by a file and has no script to pin.
    execute "UPDATE tasks SET pin = name, accepted_pin = name WHERE name = 'dokkit:update'"
  end

  def down do
    alter table(:tasks) do
      remove :pin
      remove :accepted_pin
    end
  end
end
