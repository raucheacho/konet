defmodule KonetWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :konet

  @session_options [
    store: :cookie,
    key: "_konet_key",
    signing_salt: "konet_salt",
    same_site: "Lax"
  ]

  socket "/socket", KonetWeb.UserSocket,
    websocket: [timeout: 45_000, check_origin: false],
    longpoll: false

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

  plug Corsica,
    origins: "*",
    allow_credentials: false,
    allow_headers: ["content-type", "authorization"]

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug KonetWeb.Router
end
