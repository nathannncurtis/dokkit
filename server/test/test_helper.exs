ExUnit.start()

# Partitions are made here, outside any test's transaction.
Enum.each([Date.utc_today(), ~D[2026-10-05]], &Dokkit.Logs.ensure_partition/1)
Ecto.Adapters.SQL.Sandbox.mode(Dokkit.Repo, :manual)
