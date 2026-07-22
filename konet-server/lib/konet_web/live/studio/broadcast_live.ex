defmodule KonetWeb.Studio.BroadcastLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Broadcast",
       channel: "",
       event: "message",
       payload: ~s({"text": "Hello from Studio!"}),
       result: nil
     )}
  end

  @impl true
  def handle_event("broadcast", params, socket) do
    channel = String.trim(params["channel"] || "")
    event = String.trim(params["event"] || "message")
    raw_payload = String.trim(params["payload"] || "{}")

    cond do
      channel == "" ->
        {:noreply, assign(socket, result: {:error, "Channel name is required"})}

      true ->
        case Jason.decode(raw_payload) do
          {:ok, payload} ->
            KonetWeb.Endpoint.broadcast("room:#{channel}", event, payload)

            Konet.Metrics.message_sent()
            Konet.History.record(channel, event, payload)

            {:noreply,
             assign(socket,
               channel: channel,
               event: event,
               payload: raw_payload,
               result: {:ok, "Broadcast sent to room:#{channel} — event: #{event}"}
             )}

          {:error, _} ->
            {:noreply, assign(socket, result: {:error, "Invalid JSON payload"})}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">Broadcast</h2>
      <p class="subtitle">Send a message to any channel from the Studio.</p>

      <form phx-submit="broadcast" class="broadcast-form">
        <div class="form-field">
          <label class="form-label">Channel</label>
          <input
            type="text"
            name="channel"
            value={@channel}
            placeholder="lobby"
            class="form-input mono"
            autocomplete="off"
          />
          <div class="form-hint">Without the <span class="mono">room:</span> prefix</div>
        </div>

        <div class="form-field">
          <label class="form-label">Event</label>
          <input
            type="text"
            name="event"
            value={@event}
            placeholder="message"
            class="form-input mono"
            autocomplete="off"
          />
        </div>

        <div class="form-field">
          <label class="form-label">Payload (JSON)</label>
          <textarea
            name="payload"
            rows="6"
            class="form-input mono"
            placeholder='{"key": "value"}'
          ><%= @payload %></textarea>
        </div>

        <button type="submit" class="btn btn-primary">Send Broadcast</button>
      </form>

      <%= if @result do %>
        <div class={"result-banner result-#{if elem(@result, 0) == :ok, do: "ok", else: "err"}"}>
          <%= elem(@result, 1) %>
        </div>
      <% end %>
    </div>
    """
  end
end
