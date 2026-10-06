defmodule Dokkit.Repo.Migrations.AddErrorMessages do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :keep_messages, :boolean, null: false, default: false
    end

    alter table(:error_events) do
      add :message, :text
    end
  end
end
