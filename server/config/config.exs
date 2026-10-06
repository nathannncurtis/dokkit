# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dokkit, Dokkit.Repo, parameters: [timezone: "UTC"]

config :dokkit,
  ecto_repos: [Dokkit.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :dokkit, DokkitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DokkitWeb.ErrorHTML, json: DokkitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dokkit.PubSub,
  live_view: [signing_salt: "C79WP30N"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dokkit: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Names that never reach the logs: passwords, tokens, keys and the addresses that carry one.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "key",
  "pushover_user",
  "smtp_user",
  "ntfy_url",
  "webhook_url",
  "heartbeat_url"
]

config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
