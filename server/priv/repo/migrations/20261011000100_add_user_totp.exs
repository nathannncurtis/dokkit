defmodule Dokkit.Repo.Migrations.AddUserTotp do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret, :text
      add :totp_on, :boolean, null: false, default: false
      add :totp_step, :bigint, null: false, default: 0
    end
  end
end
