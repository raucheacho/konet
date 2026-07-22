defmodule KonetWeb.Studio.PresenceLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Konet.PubSub, "studio:channels")
    end

    {:ok,
     assign(socket,
       page_title: "Presence",
       presence_map: build_presence_map(),
       selected_room: nil,
       selected_user: nil,
       panel_open: false
     )}
  end

  @impl true
  def handle_info(:channels_updated, socket) do
    {:noreply, assign(socket, presence_map: build_presence_map())}
  end

  @impl true
  def handle_event("select_user", %{"room" => room, "user" => user_id}, socket) do
    {:noreply, assign(socket, selected_room: room, selected_user: user_id, panel_open: true)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, panel_open: false)}
  end

  defp build_presence_map do
    Konet.ChannelRegistry.list()
    |> Enum.map(fn %{id: room_id} ->
      users =
        Konet.Presence.list("room:#{room_id}")
        |> Enum.map(fn {user_id, %{metas: [meta | _]}} ->
          %{
            user_id: user_id,
            role: Map.get(meta, :role, "user"),
            online_at: Map.get(meta, :online_at)
          }
        end)

      %{room: room_id, users: users}
    end)
    |> Enum.filter(fn %{users: u} -> length(u) > 0 end)
  end

  defp user_meta(nil, _user_id), do: %{}

  defp user_meta(room_id, user_id) do
    case Map.get(Konet.Presence.list("room:#{room_id}"), user_id) do
      %{metas: [meta | _]} -> meta
      _ -> %{}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">Presence</h2>

      <%= if Enum.empty?(@presence_map) do %>
        <div class="empty-state">
          <div class="empty-icon">◉</div>
          <p>No users connected.</p>
        </div>
      <% else %>
        <%= for room <- @presence_map do %>
          <div class="presence-room">
            <div class="room-header">
              <span class="mono accent">room:<%= room.room %></span>
              <span class="badge badge-purple"><%= length(room.users) %> users</span>
            </div>
            <div class="user-list">
              <%= for user <- room.users do %>
                <div
                  class="user-row row-clickable"
                  phx-click="select_user"
                  phx-value-room={room.room}
                  phx-value-user={user.user_id}
                >
                  <div class="user-avatar"><%= String.first(user.user_id) |> String.upcase() %></div>
                  <div class="user-info">
                    <div class="mono"><%= user.user_id %></div>
                    <div class="muted"><%= user.role %></div>
                  </div>
                  <div class="online-dot"></div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>

      <% meta = user_meta(@selected_room, @selected_user) %>
      <.detail_panel :if={@selected_user} open={@panel_open} title={@selected_user} on_close="close_detail">
        <.detail_section text="Room">
          <.detail_row label="topic" value={"room:#{@selected_room}"} />
        </.detail_section>
        <.detail_section text="Metadata">
          <.detail_row :for={{key, value} <- meta} label={to_string(key)} value={inspect(value)} />
        </.detail_section>
      </.detail_panel>
    </div>
    """
  end
end
