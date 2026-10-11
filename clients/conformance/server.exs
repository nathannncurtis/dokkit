db = System.fetch_env!("CONF_DB")
port = String.to_integer(System.fetch_env!("CONF_PORT"))
url = "ecto://postgres:postgres@localhost/#{db}"

Application.put_env(:dokkit, Dokkit.Repo, url: url, pool_size: 3)

endpoint = Application.get_env(:dokkit, DokkitWeb.Endpoint, [])

Application.put_env(
  :dokkit,
  DokkitWeb.Endpoint,
  Keyword.merge(endpoint,
    http: [ip: {127, 0, 0, 1}, port: port],
    server: true,
    check_origin: false,
    watchers: [],
    live_reload: [],
    code_reloader: false
  )
)

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
Ecto.Adapters.Postgres.storage_down(Dokkit.Repo.config())
Ecto.Adapters.Postgres.storage_up(Dokkit.Repo.config())
{:ok, _, _} = Ecto.Migrator.with_repo(Dokkit.Repo, &Ecto.Migrator.run(&1, :up, all: true))

{:ok, _} = Application.ensure_all_started(:dokkit)
{:ok, %{key: key}} = Dokkit.Estate.add_app(%{"name" => "conformance"})
File.write!(System.fetch_env!("CONF_KEY_FILE"), key)
IO.puts("listening on #{port}")
Process.sleep(:infinity)
