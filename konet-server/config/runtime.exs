import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  jwt_secret =
    System.get_env("KONET_JWT_SECRET") ||
      raise "environment variable KONET_JWT_SECRET is missing."

  host = System.get_env("KONET_HOST", "localhost")
  port = String.to_integer(System.get_env("KONET_PORT", "4000"))

  config :konet, KonetWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :konet,
    jwt_secret: jwt_secret,
    anon_key: System.get_env("KONET_ANON_KEY"),
    service_key: System.get_env("KONET_SERVICE_KEY")
end

if config_env() == :dev do
  config :konet, KonetWeb.Endpoint,
    secret_key_base: System.get_env("SECRET_KEY_BASE", "dev-secret-key-base-not-for-production-change-this-now-must-be-64-chars-minimum!!")
end
