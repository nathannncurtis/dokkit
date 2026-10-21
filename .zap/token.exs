Application.put_env(
  :dokkit,
  Dokkit.Repo,
  Keyword.merge(Application.get_env(:dokkit, Dokkit.Repo, []), database: "dokkit_sample", pool_size: 2)
)

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Dokkit.Repo.start_link()
{text, _} = Dokkit.Keys.mint(:user, %{label: "zap", scopes: ["admin"]})
File.write!(System.fetch_env!("ZAP_TOKEN_FILE"), text)
