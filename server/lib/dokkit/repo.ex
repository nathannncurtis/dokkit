defmodule Dokkit.Repo do
  use Ecto.Repo,
    otp_app: :dokkit,
    adapter: Ecto.Adapters.Postgres
end
