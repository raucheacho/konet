import Config

config :konet, KonetWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("a", 64),
  server: false

config :konet,
  jwt_secret: "test-jwt-secret-at-least-32-characters!!",
  anon_key: nil,
  service_key: nil,
  studio_password: nil

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
