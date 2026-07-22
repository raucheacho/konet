import Config

config :konet, KonetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KonetWeb.ErrorHTML, json: KonetWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Konet.PubSub,
  live_view: [signing_salt: "Xp4kR9mN"]

config :konet,
  jwt_secret: "change-me-in-production-min-32-chars!!",
  anon_key: nil,
  service_key: nil,
  studio_password: nil,
  rate_limit_messages: 60,
  rate_limit_connections: 200,
  history_limit: 0,
  webhook_url: nil,
  webhook_secret: nil

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.21.5",
  konet: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
