defmodule KonetWeb.Studio.LogsLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Konet.PubSub, "studio:logs")
    end

    {:ok,
     socket
     |> assign(page_title: "Logs", paused: false, log_count: 0)
     |> stream(:logs, [])}
  end

  @impl true
  def handle_info(_event, %{assigns: %{paused: true}} = socket) do
    {:noreply, socket}
  end

  def handle_info(%{type: _} = event, socket) do
    entry = Map.put(event, :id, "log-#{System.unique_integer([:positive])}")
    {:noreply,
     socket
     |> assign(log_count: socket.assigns.log_count + 1)
     |> stream_insert(:logs, entry, at: 0)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("clear", _, socket) do
    {:noreply, socket |> assign(log_count: 0) |> stream(:logs, [], reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <div class="page-header">
        <h2 class="page-title">Live Logs</h2>
        <div class="page-actions">
          <button class="btn btn-sm" phx-click="toggle_pause">
            <%= if @paused, do: "▶ Resume", else: "⏸ Pause" %>
          </button>
          <button class="btn btn-sm btn-danger" phx-click="clear">Clear</button>
        </div>
      </div>

      <div class="log-stream" id="log-stream" phx-update="stream">
        <div :for={{dom_id, log} <- @streams.logs} id={dom_id} class={"log-entry log-#{log.type}"}>
          <span class="log-time mono"><%= log.timestamp %></span>
          <span class={"log-type badge badge-#{type_color(log.type)}"}><%= log.type %></span>
          <span class="log-data mono"><%= inspect(log.data) %></span>
        </div>
      </div>

      <div :if={@log_count == 0} class="empty-state">
        <div class="empty-icon">📋</div>
        <p>Waiting for events...</p>
      </div>
    </div>
    """
  end

  defp type_color("join"), do: "green"
  defp type_color("leave"), do: "red"
  defp type_color("broadcast"), do: "purple"
  defp type_color(_), do: "blue"
end
