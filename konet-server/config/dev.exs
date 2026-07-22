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
config :konet,
  jwt_secret: "change-me-in-production-min-32-chars!!",
  anon_key: nil,
  service_key: nil

config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
