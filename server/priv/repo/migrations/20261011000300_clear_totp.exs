defmodule Dokkit.Repo.Migrations.ClearTotp do
  use Ecto.Migration

  def up, do: execute("UPDATE users SET totp_on = false, totp_secret = NULL, totp_step = 0")
  def down, do: :ok
end
