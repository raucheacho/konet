import Config

# Parses KONET_ALLOWED_ORIGINS: unset or "*" means open (check_origin false),
# otherwise a comma-separated list of allowed origins for WebSocket upgrades.
parse_origins = fn
  nil -> false
  "" -> false
  "*" -> false
  raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

parse_int = fn var, default ->
  case System.get_env(var) do
    nil -> default
    "" -> default
    raw -> String.to_integer(raw)
  end
end

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
    secret_key_base: secret_key_base,
    check_origin: parse_origins.(System.get_env("KONET_ALLOWED_ORIGINS"))

  config :konet,
    jwt_secret: jwt_secret,
    anon_key: System.get_env("KONET_ANON_KEY"),
    service_key: System.get_env("KONET_SERVICE_KEY"),
    studio_password: System.get_env("KONET_STUDIO_PASSWORD"),
    rate_limit_messages: parse_int.("KONET_RATE_LIMIT", 60),
    rate_limit_connections: parse_int.("KONET_CONN_RATE_LIMIT", 200),
    history_limit: parse_int.("KONET_HISTORY_LIMIT", 0),
    webhook_url: System.get_env("KONET_WEBHOOK_URL"),
    webhook_secret: System.get_env("KONET_WEBHOOK_SECRET")
end

if config_env() == :dev do
  config :konet, KonetWeb.Endpoint,
    secret_key_base:
      System.get_env(
        "SECRET_KEY_BASE",
        "dev-secret-key-base-not-for-production-change-this-now-must-be-64-chars-minimum!!"
      )

  config :konet,
    studio_password: System.get_env("KONET_STUDIO_PASSWORD"),
    rate_limit_messages: parse_int.("KONET_RATE_LIMIT", 60),
    rate_limit_connections: parse_int.("KONET_CONN_RATE_LIMIT", 200),
    history_limit: parse_int.("KONET_HISTORY_LIMIT", 0),
    webhook_url: System.get_env("KONET_WEBHOOK_URL"),
    webhook_secret: System.get_env("KONET_WEBHOOK_SECRET")
end
