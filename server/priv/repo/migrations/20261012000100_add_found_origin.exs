defmodule Dokkit.Repo.Migrations.AddFoundOrigin do
  use Ecto.Migration

  def change do
    alter table(:found) do
      add :origin, :string
      add :why, :text
    end
  end
end
