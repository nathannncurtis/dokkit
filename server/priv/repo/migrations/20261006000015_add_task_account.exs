defmodule Dokkit.Repo.Migrations.AddTaskAccount do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :as_system, :boolean, null: false, default: false
      # The built-in update task belongs to a machine and to no service.
      modify :service_id, :binary_id, null: true, from: {:binary_id, null: false}
    end
  end
end
