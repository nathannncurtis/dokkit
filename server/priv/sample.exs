# Builds an invented estate and serves the real server on it, to look at the interface.
# Run from server/: mix run --no-start priv/sample.exs. It makes its own database, dokkit_sample.
# Every name in it is invented.

Logger.configure(level: :warning)

# Its own database and port; no sweep, so nothing alters the sample after it is built.
Application.put_env(
  :dokkit,
  Dokkit.Repo,
  Keyword.merge(Application.get_env(:dokkit, Dokkit.Repo, []),
    database: System.get_env("DOKKIT_SAMPLE_DB", "dokkit_sample"),
    pool_size: 5
  )
)

Application.put_env(
  :dokkit,
  DokkitWeb.Endpoint,
  Keyword.merge(Application.get_env(:dokkit, DokkitWeb.Endpoint, []),
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("DOKKIT_SAMPLE_PORT", "4010"))],
    server: true,
    code_reloader: false,
    watchers: []
  )
)

Application.put_env(:dokkit, :watch, false)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
config = Dokkit.Repo.config()
Ecto.Adapters.Postgres.storage_down(config)
:ok = Ecto.Adapters.Postgres.storage_up(config)
path = Path.expand("repo/migrations", __DIR__)
{:ok, _, _} = Ecto.Migrator.with_repo(Dokkit.Repo, &Ecto.Migrator.run(&1, path, :up, all: true))
{:ok, _} = Application.ensure_all_started(:dokkit)

Dokkit.Demo.Sample.build()

inbox = Dokkit.Read.inbox()
cells = Dokkit.Read.day().machines |> Enum.flat_map(& &1.cells) |> Enum.frequencies()

IO.puts("""

Sample estate ready.
  Address   http://127.0.0.1:#{System.get_env("DOKKIT_SAMPLE_PORT", "4010")}
  Sign in   sample / sample-password-1
  Needs you #{length(inbox.needs_you)}, Soon #{length(inbox.soon)}, Not watched #{length(inbox.not_watched)}, Snoozed #{length(inbox.snoozed)}
  Other environments #{Enum.sum(for e <- inbox.other_environments, do: length(e.issues))}, fine #{inbox.fine.services} services on #{inbox.fine.machines} machines
  The last day: #{inspect(cells)}
""")

Process.sleep(:infinity)
