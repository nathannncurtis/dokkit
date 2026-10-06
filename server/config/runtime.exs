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
config :dokkit, programs: System.get_env("DOKKIT_PROGRAMS")

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

  cert = System.get_env("DOKKIT_CERT")

  # With a certificate of its own, Dokkit serves TLS itself and machines pin it when they enrol.
  # Without one it speaks plain HTTP behind a proxy that holds a real certificate.
  if cert do
    port = String.to_integer(System.get_env("PORT", "443"))

    config :dokkit, DokkitWeb.Endpoint,
      url: [host: host, port: port, scheme: "https"],
      https: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: port,
        certfile: cert,
        keyfile: System.fetch_env!("DOKKIT_CERT_KEY")
      ],
      http: false,
      secret_key_base: secret_key_base

    config :dokkit, cert: cert
  else
    config :dokkit, DokkitWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
      secret_key_base: secret_key_base
  end
end
