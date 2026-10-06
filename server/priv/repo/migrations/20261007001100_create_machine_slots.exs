defmodule Dokkit.Repo.Migrations.CreateMachineSlots do
  use Ecto.Migration

  def change do
    create table(:machine_slots, primary_key: false) do
      add :machine_id, references(:machines, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :slot, :utc_datetime, null: false, primary_key: true
    end
  end
end
