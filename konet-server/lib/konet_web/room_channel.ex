defmodule KonetWeb.RoomChannel do
  use Phoenix.Channel
  alias Konet.{Presence, Metrics, ChannelRegistry, RateLimiter}

  @impl true
  def join("room:" <> room_id, _params, socket) do
    send(self(), {:after_join, room_id})
    ChannelRegistry.channel_joined(room_id)
    log_event("join", %{room: room_id, user: socket.assigns.user_id})
    {:ok, assign(socket, :room_id, room_id)}
  end

  @impl true
  def handle_info({:after_join, room_id}, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.user_id, %{
        online_at: System.system_time(:second),
        room: room_id,
        role: socket.assigns.role
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast", %{"event" => event, "payload" => payload}, socket) do
    case RateLimiter.check_message(socket.assigns.socket_id) do
      :ok ->
        Metrics.message_sent()
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

  @impl true
  def terminate(_reason, socket) do
    Metrics.connection_closed()
    ChannelRegistry.channel_left(socket.assigns[:room_id] || "unknown")
    log_event("leave", %{room: socket.assigns[:room_id], user: socket.assigns.user_id})
    :ok
  end

  defp log_event(type, data) do
    Phoenix.PubSub.broadcast(Konet.PubSub, "studio:logs", %{
      type: type,
      data: data,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
