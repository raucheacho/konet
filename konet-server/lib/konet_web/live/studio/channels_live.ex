defmodule KonetWeb.Studio.ChannelsLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Konet.PubSub, "studio:channels")
    end

    {:ok,
     assign(socket,
       page_title: "Channels",
       channels: Konet.ChannelRegistry.list(),
       selected_room: nil,
       panel_open: false
     )}
  end

  @impl true
  def handle_info(:channels_updated, socket) do
    {:noreply, assign(socket, channels: Konet.ChannelRegistry.list())}
  end

  @impl true
  def handle_event("select_room", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_room: id, panel_open: true)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, panel_open: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">Active Channels</h2>

      <%= if Enum.empty?(@channels) do %>
        <div class="empty-state">
          <div class="empty-icon">⊕</div>
          <p>No active channels yet.</p>
          <p class="muted mono">Connect a client to see channels here.</p>
        </div>
      <% else %>
        <div class="table-container">
          <table class="data-table">
            <thead>
              <tr>
                <th>Channel</th>
                <th>Subscribers</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <%= for ch <- @channels do %>
                <tr class="row-clickable" phx-click="select_room" phx-value-id={ch.id}>
                  <td class="mono accent"><%= "room:#{ch.id}" %></td>
                  <td class="mono"><%= ch.subscribers %></td>
                  <td><span class="badge badge-green">active</span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <% presence = room_presence(@selected_room) %>
      <.detail_panel :if={@selected_room} open={@panel_open} title={"room:#{@selected_room}"} on_close="close_detail">
        <.detail_section text="Subscribers">
          <.detail_row :for={user <- presence} label={user.user_id} value={user.role} />
          <p :if={presence == []} class="muted">No one connected right now.</p>
        </.detail_section>
      </.detail_panel>
    </div>
    """
  end

  defp room_presence(nil), do: []

  defp room_presence(room_id) do
    Konet.Presence.list("room:#{room_id}")
    |> Enum.map(fn {user_id, %{metas: [meta | _]}} ->
      %{user_id: user_id, role: Map.get(meta, :role, "user")}
    end)
  end
end
