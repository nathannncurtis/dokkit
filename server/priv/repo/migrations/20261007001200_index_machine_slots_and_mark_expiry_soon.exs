defmodule Dokkit.Repo.Migrations.IndexMachineSlotsAndMarkExpirySoon do
  use Ecto.Migration

  def change do
    create index(:machine_slots, [:slot])

    execute(
      "UPDATE issues SET soon = true WHERE kind = 'expiry' AND state = 'degraded' AND closed_at IS NULL",
      ""
    )
  end
end
