import Config

config :konet, KonetWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev-secret-key-base-not-for-production-change-this-now-must-be-64-chars-minimum!!",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:konet, ~w(--sourcemap=inline --watch)]}
  ]

# Env-configurable keys (studio_password, rate limits, history, webhooks)
# are read at boot in runtime.exs so they don't require a recompile.
#
# jwt_secret is deliberately absent: runtime.exs takes KONET_SECRET_FILE, then
# KONET_JWT_SECRET, then generates a random one for the run. It used to default
# to the placeholder published in this repository, which a dev server reachable
# from outside localhost would happily accept tokens against.
config :konet,
  anon_key: nil,
  service_key: nil

config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
