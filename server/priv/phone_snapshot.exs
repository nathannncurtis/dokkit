# Writes spec/phone-cases/snapshot.json from the sample estate. Run priv/sample.exs once first, so database dokkit_sample exists.
# Run from server/: mix run --no-start priv/phone_snapshot.exs
Logger.configure(level: :warning)

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
    url: [host: "northwind.example.com", scheme: "https", port: 443],
    server: false
  )
)

Application.put_env(:dokkit, :watch, false)
{:ok, _} = Application.ensure_all_started(:dokkit)

now = DateTime.utc_now()
doc = Dokkit.Phones.Snapshot.build(DateTime.to_unix(now), now)
out = Path.expand("../../spec/phone-cases/snapshot.json", __DIR__)
File.write!(out, Jason.encode!(doc, pretty: true) <> "\n")
IO.puts("Wrote #{out}: #{byte_size(Jason.encode!(doc))} bytes, #{byte_size(:zlib.gzip(Jason.encode!(doc)))} compressed.")
