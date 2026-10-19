import Config

# A Windows service is not started through a script, so there is nowhere to set variables for
# it. Its settings are lines of NAME=value in a file only administrators can read. A variable
# that is already set wins.
settings = Path.join(System.get_env("ProgramData") || "", "Dokkit/settings.env")

if config_env() == :prod and Path.type(settings) == :absolute and File.regular?(settings) do
  # Notepad and PowerShell 5 write a byte order mark first; people leave spaces after values.
  text = settings |> File.read!() |> String.trim_leading("﻿")

  for line <- String.split(text, ~r/\r?\n/, trim: true),
      [name, value] <- [String.split(line, "=", parts: 2)],
      name = String.trim(name),
      name != "",
      System.get_env(name) == nil,
      do: System.put_env(name, String.trim(value))
end

# A file log, for a service that has no console.
if log_dir = System.get_env("DOKKIT_LOG_DIR") do
  config :logger, :default_handler,
    config: [
      file: String.to_charlist(Path.join(log_dir, "dokkit.log")),
      max_no_bytes: 10_000_000,
      max_no_files: 5
    ]
end

if System.get_env("PHX_SERVER") do
  config :dokkit, DokkitWeb.Endpoint, server: true
end

config :dokkit, DokkitWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  config :dokkit, DokkitWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"lib/dokkit_web/router\.ex$"E,
        ~r"lib/dokkit_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# The folder old log months are archived to. Without it, every month stays in the database.
config :dokkit, archive: System.get_env("DOKKIT_ARCHIVE")

if config_env() != :test,
  do:
    config(:dokkit,
      shared_relay: System.get_env("DOKKIT_SHARED_RELAY", "https://relay.dokkit.dev"),
      shared_heartbeat: System.get_env("DOKKIT_SHARED_HEARTBEAT", "https://beat.dokkit.dev")
    )

config :dokkit, programs: System.get_env("DOKKIT_PROGRAMS")

# Signed releases the updaters fetch. Beside the settings file in production.
releases =
  cond do
    config_env() != :prod -> Path.join(System.tmp_dir!(), "dokkit-releases-#{config_env()}")
    Path.type(settings) == :absolute -> Path.join(Path.dirname(settings), "releases")
    true -> "releases"
  end

config :dokkit, releases: System.get_env("DOKKIT_RELEASES") || releases

# The second certificate, put in place through the API. Beside the settings file in production.
tls =
  cond do
    config_env() != :prod -> Path.join(System.tmp_dir!(), "dokkit-tls-#{config_env()}")
    Path.type(settings) == :absolute -> Path.join(Path.dirname(settings), "tls")
    true -> "tls"
  end

config :dokkit, tls: System.get_env("DOKKIT_TLS") || tls

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is missing. For example: ecto://USER:PASS@HOST/DATABASE"

  config :dokkit, Dokkit.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing. Make one with: mix phx.gen.secret"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is missing. It is the name people and machines reach Dokkit by."

  # Browsers send the name in lower case, and the live connection's origin is compared exactly.
  host = String.downcase(host)

  cert = System.get_env("DOKKIT_CERT")

  # On Windows this listens on IPv4 and Dokkit.Application adds an IPv6 listener.
  any = if match?({:win32, _}, :os.type()), do: {0, 0, 0, 0}, else: {0, 0, 0, 0, 0, 0, 0, 0}

  # With a certificate of its own, Dokkit serves TLS itself and machines pin it when they enrol.
  # Without one it speaks plain HTTP behind a proxy that holds a real certificate.
  if cert do
    port = String.to_integer(System.get_env("PORT", "443"))

    config :dokkit, DokkitWeb.Endpoint,
      url: [host: host, port: port, scheme: "https"],
      https: [
        ip: any,
        port: port,
        certfile: cert,
        keyfile: System.fetch_env!("DOKKIT_CERT_KEY"),
        thousand_island_options: [transport_options: [sni_fun: &Dokkit.Certificate.sni/1]]
      ],
      http: false,
      secret_key_base: secret_key_base

    config :dokkit, cert: cert
  else
    config :dokkit, DokkitWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: any],
      secret_key_base: secret_key_base

    config :dokkit, behind_proxy: true
  end
end
