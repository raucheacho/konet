defmodule KonetWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :konet

  @session_options [
    store: :cookie,
    key: "_konet_key",
    signing_salt: "konet_salt",
    same_site: "Lax"
  ]

  # check_origin comes from the endpoint config (KONET_ALLOWED_ORIGINS at
  # runtime in prod, false in dev) rather than being pinned open here.
  #
  # :x_headers is requested so UserSocket can resolve the real client IP behind
  # a reverse proxy. It is only *trusted* when KONET_TRUST_PROXY_HEADERS says
  # there is one — see KonetWeb.UserSocket.extract_ip/1.
  socket "/socket", KonetWeb.UserSocket,
    websocket: [timeout: 45_000, connect_info: [:peer_data, :x_headers]],
    longpoll: [connect_info: [:peer_data, :x_headers]]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :konet,
    gzip: false,
    only: KonetWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  # Same allow-list as the WebSocket origin check. These used to disagree —
  # check_origin honoured KONET_ALLOWED_ORIGINS while this was pinned to "*",
  # so locking the env var down restricted WebSocket upgrades and left the REST
  # API open to every origin.
  plug Corsica,
    origins: {KonetWeb.Cors, :allowed?},
    allow_credentials: false,
    allow_headers: ["content-type", "authorization"]

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug KonetWeb.Router
end
