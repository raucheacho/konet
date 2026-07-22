defmodule KonetWeb.AdminController do
  use KonetWeb, :controller
  alias Konet.{Auth, Presence, Metrics, ChannelRegistry}

  def root(conn, _params) do
    json(conn, %{
      name: "Konet",
      version: "0.1.0",
      status: "running",
      studio: "/studio"
    })
  end

  def health(conn, _params) do
    m = Metrics.get()

    json(conn, %{
      status: "ok",
      version: "0.1.0",
      connections: m.connections,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), m.started_at, :second)
    })
  end

  def channels(conn, _params) do
    case require_service_key(conn) do
      {:ok, _claims} -> json(conn, %{channels: ChannelRegistry.list()})
      {:halt, conn} -> conn
    end
  end

  def presence(conn, %{"channel" => channel}) do
    case require_service_key(conn) do
      {:ok, _claims} ->
        presence =
          Presence.list("room:#{channel}")
          |> Enum.map(fn {user_id, %{metas: metas}} ->
            %{user_id: user_id, metas: metas}
          end)

        json(conn, %{channel: channel, presence: presence, count: length(presence)})

      {:halt, conn} ->
        conn
    end
  end

  def broadcast(conn, %{"channel" => channel, "event" => event, "payload" => payload}) do
    case require_service_key(conn) do
      {:ok, _claims} ->
        KonetWeb.Endpoint.broadcast("room:#{channel}", event, payload)
        Metrics.message_sent()
        Konet.History.record(channel, event, payload)
        json(conn, %{ok: true, channel: channel, event: event})

      {:halt, conn} ->
        conn
    end
  end

  def metrics(conn, _params) do
    case require_service_key(conn) do
      {:ok, _claims} ->
        m = Metrics.get()

        json(conn, %{
          connections: m.connections,
          messages_total: m.messages_total,
          messages_per_second: m.messages_rate,
          uptime_seconds: DateTime.diff(DateTime.utc_now(), m.started_at, :second),
          channels: length(ChannelRegistry.list())
        })

      {:halt, conn} ->
        conn
    end
  end

  def prometheus(conn, _params) do
    case require_service_key(conn) do
      {:ok, _claims} ->
        m = Metrics.get()
        uptime = DateTime.diff(DateTime.utc_now(), m.started_at, :second)

        body = """
        # HELP konet_connections Current WebSocket connections
        # TYPE konet_connections gauge
        konet_connections #{m.connections}
        # HELP konet_channels Active channels
        # TYPE konet_channels gauge
        konet_channels #{length(ChannelRegistry.list())}
        # HELP konet_messages_total Messages broadcast since boot
        # TYPE konet_messages_total counter
        konet_messages_total #{m.messages_total}
        # HELP konet_messages_per_second Messages broadcast in the last second
        # TYPE konet_messages_per_second gauge
        konet_messages_per_second #{m.messages_rate}
        # HELP konet_uptime_seconds Seconds since boot
        # TYPE konet_uptime_seconds counter
        konet_uptime_seconds #{uptime}
        """

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, body)

      {:halt, conn} ->
        conn
    end
  end

  defp require_service_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Auth.verify(token) do
          {:ok, %{"role" => "service"} = claims} ->
            {:ok, claims}

          _ ->
            {:halt, send_unauthorized(conn, "invalid or insufficient token")}
        end

      _ ->
        {:halt, send_unauthorized(conn, "missing Authorization: Bearer <service_key>")}
    end
  end

  defp send_unauthorized(conn, reason) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: reason})
    |> halt()
  end
end
