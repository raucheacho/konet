import Config

# Parses KONET_ALLOWED_ORIGINS: unset or "*" means open (check_origin false),
# otherwise a comma-separated list of allowed origins for WebSocket upgrades.
parse_origins = fn
  nil -> false
  "" -> false
  "*" -> false
  raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# A rotated secret is written here by Konet.Auth.rotate!/0 and read back on the
# next boot, which is what makes Studio rotation survive a restart. It takes
# precedence over KONET_JWT_SECRET: the file is the more recent of the two by
# construction.
read_secret_file = fn ->
  case System.get_env("KONET_SECRET_FILE") do
    path when is_binary(path) and path != "" ->
      case File.read(path) do
        {:ok, contents} ->
          case String.trim(contents) do
            "" -> {path, nil}
            secret -> {path, secret}
          end

        {:error, _} ->
          # Missing is normal on first boot — rotate!/0 creates it.
          {path, nil}
      end

    _ ->
      {nil, nil}
  end
end

parse_bool = fn var, default ->
  case System.get_env(var) do
    nil -> default
    raw -> String.downcase(String.trim(raw)) in ~w(1 true yes on)
  end
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

  {secret_file, persisted_secret} = read_secret_file.()

  jwt_secret =
    persisted_secret || System.get_env("KONET_JWT_SECRET") ||
      raise "environment variable KONET_JWT_SECRET is missing."

  host = System.get_env("KONET_HOST", "localhost")
  port = String.to_integer(System.get_env("KONET_PORT", "4000"))

  allowed_origins = parse_origins.(System.get_env("KONET_ALLOWED_ORIGINS"))

  config :konet, KonetWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    check_origin: allowed_origins

  config :konet,
    # Same list the socket's check_origin uses, so the REST API and the
    # WebSocket agree on who may call them. `false` here means "*".
    allowed_origins: (if is_list(allowed_origins), do: allowed_origins, else: nil),
    secret_file: secret_file,
    jwt_secret: jwt_secret,
    anon_key: System.get_env("KONET_ANON_KEY"),
    service_key: System.get_env("KONET_SERVICE_KEY"),
    studio_password: System.get_env("KONET_STUDIO_PASSWORD"),
    rate_limit_messages: parse_int.("KONET_RATE_LIMIT", 60),
    rate_limit_connections: parse_int.("KONET_CONN_RATE_LIMIT", 200),
    # Binary frames arrive at a media rate, not a message rate: 20 ms frames
    # are 50 per second on their own. Sharing the message budget would have a
    # talker starve their own non-media events.
    rate_limit_binary: parse_int.("KONET_RATE_LIMIT_BINARY", 120),
    floor_max_hold_ms: parse_int.("KONET_FLOOR_MAX_HOLD_MS", 30_000),
    history_limit: parse_int.("KONET_HISTORY_LIMIT", 0),
    # How long a room's replay buffer outlives its last message. Bounds the
    # table for workloads that mint many short-lived room names.
    history_ttl_seconds: parse_int.("KONET_HISTORY_TTL", 900),
    # Only set this when a reverse proxy really is in front: it makes the
    # per-IP connection limit read X-Forwarded-For, which a direct client
    # could otherwise forge to get its own private budget.
    trust_proxy_headers: parse_bool.("KONET_TRUST_PROXY_HEADERS", false),
    # Logging every accepted broadcast makes Konet.LogBuffer the serialization
    # point for the whole server under load. Off is the high-throughput
    # setting; join/leave and floor entries are unaffected either way.
    log_broadcasts: parse_bool.("KONET_LOG_BROADCASTS", true),
    webhook_url: System.get_env("KONET_WEBHOOK_URL"),
    webhook_secret: System.get_env("KONET_WEBHOOK_SECRET"),
    # Total attempts per event, not extra ones. 1 disables retrying.
    webhook_retries: parse_int.("KONET_WEBHOOK_RETRIES", 3)
end

if config_env() == :dev do
  # KONET_PORT and KONET_HOST are honoured in dev too. They used to be read only
  # in the :prod block, so running a second server from source — for the
  # conformance harness, or just alongside one already running — meant editing
  # dev.exs. That kind of drift between the two blocks is invisible until it
  # wastes an afternoon.
  config :konet, KonetWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("KONET_PORT", "4000"))],
    url: [host: System.get_env("KONET_HOST", "localhost")],
    secret_key_base:
      System.get_env(
        "SECRET_KEY_BASE",
        "dev-secret-key-base-not-for-production-change-this-now-must-be-64-chars-minimum!!"
      )

  # KONET_JWT_SECRET is honoured in dev too. Without this, running the server
  # from source against a backend that mints its own tokens refuses every
  # connection — and says only "REFUSED CONNECTION", which is a long way from
  # "the secrets differ".
  #
  # When neither it nor a secret file is set, a random secret is generated for
  # this run rather than falling back to the documented placeholder. That
  # placeholder is published in this repository, so a dev server reachable from
  # anywhere would accept tokens anyone could mint. Tokens simply do not survive
  # a restart now, which is the correct trade and is said out loud below.
  {dev_secret_file, dev_persisted_secret} = read_secret_file.()

  dev_jwt_secret =
    dev_persisted_secret || System.get_env("KONET_JWT_SECRET") ||
      (
        generated = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

        IO.puts(
          :stderr,
          "\n[konet] No KONET_JWT_SECRET set — generated a random one for this run:\n" <>
            "        #{generated}\n" <>
            "        Tokens signed with it stop working when the server restarts.\n" <>
            "        Set KONET_JWT_SECRET (or KONET_SECRET_FILE) to keep them.\n"
        )

        generated
      )

  config :konet,
    jwt_secret: dev_jwt_secret,
    secret_file: dev_secret_file,
    allowed_origins: nil,
    studio_password: System.get_env("KONET_STUDIO_PASSWORD"),
    rate_limit_messages: parse_int.("KONET_RATE_LIMIT", 60),
    rate_limit_connections: parse_int.("KONET_CONN_RATE_LIMIT", 200),
    # Binary frames arrive at a media rate, not a message rate: 20 ms frames
    # are 50 per second on their own. Sharing the message budget would have a
    # talker starve their own non-media events.
    rate_limit_binary: parse_int.("KONET_RATE_LIMIT_BINARY", 120),
    floor_max_hold_ms: parse_int.("KONET_FLOOR_MAX_HOLD_MS", 30_000),
    history_limit: parse_int.("KONET_HISTORY_LIMIT", 0),
    # How long a room's replay buffer outlives its last message. Bounds the
    # table for workloads that mint many short-lived room names.
    history_ttl_seconds: parse_int.("KONET_HISTORY_TTL", 900),
    # Only set this when a reverse proxy really is in front: it makes the
    # per-IP connection limit read X-Forwarded-For, which a direct client
    # could otherwise forge to get its own private budget.
    trust_proxy_headers: parse_bool.("KONET_TRUST_PROXY_HEADERS", false),
    # Logging every accepted broadcast makes Konet.LogBuffer the serialization
    # point for the whole server under load. Off is the high-throughput
    # setting; join/leave and floor entries are unaffected either way.
    log_broadcasts: parse_bool.("KONET_LOG_BROADCASTS", true),
    webhook_url: System.get_env("KONET_WEBHOOK_URL"),
    webhook_secret: System.get_env("KONET_WEBHOOK_SECRET"),
    # Total attempts per event, not extra ones. 1 disables retrying.
    webhook_retries: parse_int.("KONET_WEBHOOK_RETRIES", 3)
end
