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
        # Every accepted broadcast writing to LogBuffer makes that one GenServer
        # the serialization point for the whole server under load. Kept on by
        # default because the Studio Logs page is most of its value, but a
        # high-throughput deployment can turn it off with
        # KONET_LOG_BROADCASTS=false without losing the low-rate join/leave and
        # floor entries.
        if log_broadcasts?(), do: log_event("broadcast", %{room: socket.assigns.room_id, event: event})
        broadcast!(socket, event, payload)
        {:noreply, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  def handle_in("presence_state", _payload, socket) do
    {:reply, {:ok, Presence.list(socket)}, socket}
  end

  # ── Parole exclusive ────────────────────────────────────────────────────
  #
  # Half-duplex media needs an arbiter, and the channel process is the only
  # place where "who is sending" can be decided without an extra round trip:
  # the client that presses gets its answer on the connection it already has.

  def handle_in("konet:floor_acquire", _payload, socket) do
    topic = socket.topic
    user_id = socket.assigns.user_id

    case Konet.Floor.acquire(topic, user_id) do
      {:ok, ^user_id, since} ->
        # Announced to everyone, including the holder: subscribers need to know
        # a stream is starting before its first frame arrives, and the holder
        # needs the same id to stamp its frames with.
        #
        # `since` is the moment the floor was actually taken, reported by Floor
        # itself — not "now". They differ on a duplicate press, and a listener
        # joining mid-stream needs the former to show how long someone has been
        # talking.
        broadcast!(socket, "konet:floor", %{holder: user_id, since: since})
        log_event("floor_acquire", %{room: socket.assigns.room_id, user: user_id})
        {:reply, {:ok, %{holder: user_id, since: since}}, socket}

      {:error, {:held, other}} ->
        {:reply, {:error, %{reason: "floor_held", holder: other}}, socket}
    end
  end

  def handle_in("konet:floor_release", _payload, socket) do
    topic = socket.topic
    user_id = socket.assigns.user_id

    case Konet.Floor.release(topic, user_id) do
      :ok ->
        broadcast!(socket, "konet:floor", %{holder: nil, since: now_ms()})
        log_event("floor_release", %{room: socket.assigns.room_id, user: user_id})
        {:reply, :ok, socket}

      {:error, :not_holder} ->
        {:reply, {:error, %{reason: "not_holder"}}, socket}
    end
  end

  # ── Trames binaires ─────────────────────────────────────────────────────
  #
  # The hot path. At 20 ms Opus frames this runs 50 times a second per talker,
  # so it does the least possible: check the floor, fan out. Deliberately
  # absent, and each for a reason —
  #
  #   * History: buffering 50 frames a second would blow up the ETS table for
  #     a replay nobody can use. Recording audio is a durable-storage problem,
  #     not a replay-buffer one.
  #   * Per-frame logging: this is exactly the hot-path logging the audit
  #     flagged, and audio is where it would first hurt.
  #   * Rate limiting per message: the floor already allows a single sender per
  #     topic, so the budget below only exists to stop one client flooding.
  #
  # `broadcast!` with a {:binary, _} payload takes Phoenix's fastlane: the
  # frame is encoded once and written to every subscriber's socket without
  # passing through their channel processes.
  def handle_in(event, {:binary, data}, socket) do
    if Konet.Floor.holds?(socket.topic, socket.assigns.user_id) do
      case RateLimiter.check_binary(socket.assigns.socket_id) do
        :ok ->
          Metrics.message_sent()
          # `broadcast_from!`, not `broadcast!`: sending a talker their own
          # audio back is echo, and on a phone it is echo at speaker volume.
          broadcast_from!(socket, event, {:binary, data})
          {:noreply, socket}

        {:error, :rate_limited} ->
          {:reply, {:error, %{reason: "rate_limited"}}, socket}
      end
    else
      {:reply, {:error, %{reason: "floor_required"}}, socket}
    end
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

  defp unsupported_reason(_payload), do: "unsupported_event"

  defp now_ms, do: System.system_time(:millisecond)

  @impl true
  def terminate(_reason, socket) do
    # A holder who disappears mid-sentence — the tunnel case, and the common
    # one — must not leave the topic muted. Konet.Floor's monitor would free
    # the entry anyway; releasing here also tells the others to stop showing
    # someone as talking.
    user_id = socket.assigns.user_id

    if socket.assigns[:room_id] && Konet.Floor.release(socket.topic, user_id) == :ok do
      broadcast!(socket, "konet:floor", %{holder: nil, since: now_ms()})
    end

    # No connection counting here: this runs once per *channel*, and pairing it
    # with the per-*socket* increment in UserSocket made the gauge drift to zero
    # on any client that joined more than one room. Konet.Metrics monitors the
    # socket process instead.
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

  defp log_broadcasts?, do: Application.get_env(:konet, :log_broadcasts, true) != false
end
