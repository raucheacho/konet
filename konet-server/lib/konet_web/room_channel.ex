defmodule KonetWeb.RoomChannel do
  use Phoenix.Channel
  alias Konet.{Presence, Metrics, ChannelRegistry, RateLimiter}

  @impl true
  def join("room:" <> room_id, _params, socket) do
    topic = "room:" <> room_id

    if authorized?(socket, topic) do
      send(self(), {:after_join, room_id})
      ChannelRegistry.channel_joined(room_id)
      Konet.Webhooks.emit("member_joined", %{room: room_id, user: socket.assigns.user_id})
      log_event("join", %{room: room_id, user: socket.assigns.user_id})
      {:ok, assign(socket, :room_id, room_id)}
    else
      log_event("join_denied", %{room: room_id, user: socket.assigns.user_id})
      {:error, %{reason: "unauthorized"}}
    end
  end

  # A token with no "channels" claim (e.g. the shared anon/service key) can join
  # any room — same as today's behavior. A token scoped with a "channels" claim
  # (minted by the developer's own backend using the jwt_secret) may only join
  # the topics it lists. Entries may end in "*" for prefix matching
  # ("room:user-42:*" allows every room under that namespace) so one token can
  # cover a per-user namespace without minting a token per room.
  defp authorized?(socket, topic) do
    case socket.assigns[:channels] do
      allowed when is_list(allowed) -> Enum.any?(allowed, &topic_allowed?(&1, topic))
      _ -> true
    end
  end

  defp topic_allowed?(pattern, topic) when is_binary(pattern) do
    case String.split(pattern, "*", parts: 2) do
      [^topic] -> true
      [prefix, ""] -> String.starts_with?(topic, prefix)
      _ -> false
    end
  end

  defp topic_allowed?(_, _), do: false

  @impl true
  def handle_info({:after_join, room_id}, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.user_id, %{
        online_at: System.system_time(:second),
        room: room_id,
        role: socket.assigns.role
      })

    push(socket, "presence_state", Presence.list(socket))

    case Konet.History.list(room_id) do
      [] -> :ok
      messages -> push(socket, "konet:history", %{messages: messages})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast", %{"event" => event, "payload" => payload}, socket) do
    case RateLimiter.check_message(socket.assigns.socket_id) do
      :ok ->
        Metrics.message_sent()
        Konet.History.record(socket.assigns.room_id, event, payload)
        log_event("broadcast", %{room: socket.assigns.room_id, event: event})
        broadcast!(socket, event, payload)
        {:noreply, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  def handle_in("presence_state", _payload, socket) do
    {:reply, {:ok, Presence.list(socket)}, socket}
  end

  # Anything the clauses above don't understand — a typo'd event, a malformed
  # "broadcast" payload, or a binary frame (the transport decodes those into a
  # {:binary, data} payload that matches no clause here) — used to raise
  # FunctionClauseError, which takes the channel process down and drops the
  # client's connection. A client sending one bad frame should get an error
  # back, not lose its socket.
  def handle_in(event, payload, socket) do
    log_event("unhandled_in", %{room: socket.assigns[:room_id], event: event})
    {:reply, {:error, %{reason: unsupported_reason(payload), event: event}}, socket}
  end

  # Konet speaks JSON today. The Phoenix transport already handles binary
  # frames both ways, so supporting them is a broadcast-path change rather
  # than a transport one — until then, say so explicitly instead of reporting
  # a binary frame as an unknown event.
  defp unsupported_reason({:binary, _data}), do: "binary_unsupported"
  defp unsupported_reason(_payload), do: "unsupported_event"

  @impl true
  def terminate(_reason, socket) do
    Metrics.connection_closed()
    ChannelRegistry.channel_left(socket.assigns[:room_id] || "unknown")

    Konet.Webhooks.emit("member_left", %{
      room: socket.assigns[:room_id],
      user: socket.assigns.user_id
    })

    log_event("leave", %{room: socket.assigns[:room_id], user: socket.assigns.user_id})
    :ok
  end

  defp log_event(type, data) do
    Konet.LogBuffer.record(type, data)
  end
end
