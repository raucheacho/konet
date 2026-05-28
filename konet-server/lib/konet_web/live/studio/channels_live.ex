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
       channels: Konet.ChannelRegistry.list()
     )}
  end

  @impl true
  def handle_info(:channels_updated, socket) do
    {:noreply, assign(socket, channels: Konet.ChannelRegistry.list())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">Active Channels</h2>

      <%= if Enum.empty?(@channels) do %>
        <div class="empty-state">
          <div class="empty-icon">📡</div>
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
                <tr>
                  <td class="mono accent"><%= "room:#{ch.id}" %></td>
                  <td class="mono"><%= ch.subscribers %></td>
                  <td><span class="badge badge-green">active</span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end
end
