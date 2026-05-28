defmodule KonetWeb.Studio.KeysLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Keys",
       anon_key: Application.get_env(:konet, :anon_key) || get_key_from_env("KONET_ANON_KEY"),
       service_key: Application.get_env(:konet, :service_key) || get_key_from_env("KONET_SERVICE_KEY"),
       jwt_secret: mask_secret(Application.get_env(:konet, :jwt_secret, "")),
       generated: nil,
       show_secret: false
     )}
  end

  @impl true
  def handle_event("generate_anon", _, socket) do
    {:ok, token} = Konet.Auth.sign(%{"role" => "anon", "iat" => System.system_time(:second)})
    {:noreply, assign(socket, anon_key: token, generated: :anon)}
  end

  def handle_event("generate_service", _, socket) do
    {:ok, token} = Konet.Auth.sign(%{"role" => "service", "iat" => System.system_time(:second)})
    {:noreply, assign(socket, service_key: token, generated: :service)}
  end

  def handle_event("toggle_secret", _, socket) do
    {:noreply, assign(socket, show_secret: !socket.assigns.show_secret)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">API Keys</h2>
      <p class="subtitle muted">Keys are signed JWTs using your JWT secret. Update your config file after generating new keys.</p>

      <div class="key-card">
        <div class="key-header">
          <span class="key-label">Anon Key</span>
          <span class="badge badge-blue">public</span>
        </div>
        <div class="key-value mono">
          <%= if @anon_key, do: @anon_key, else: "Not configured" %>
        </div>
        <div class="key-hint muted">Use in client-side code. Grants access to public channels.</div>
        <button class="btn btn-sm btn-primary" phx-click="generate_anon">Generate New</button>
        <%= if @generated == :anon do %>
          <span class="badge badge-green ml">Generated — copy and update konet.config.toml</span>
        <% end %>
      </div>

      <div class="key-card">
        <div class="key-header">
          <span class="key-label">Service Key</span>
          <span class="badge badge-orange">private</span>
        </div>
        <div class="key-value mono">
          <%= if @service_key, do: @service_key, else: "Not configured" %>
        </div>
        <div class="key-hint muted">Server-side only. Required for admin API calls and broadcasting.</div>
        <button class="btn btn-sm btn-primary" phx-click="generate_service">Generate New</button>
        <%= if @generated == :service do %>
          <span class="badge badge-green ml">Generated — never expose this in client code</span>
        <% end %>
      </div>

      <div class="key-card">
        <div class="key-header">
          <span class="key-label">JWT Secret</span>
          <span class="badge badge-red">secret</span>
          <button class="btn btn-xs" phx-click="toggle_secret">
            <%= if @show_secret, do: "Hide", else: "Show" %>
          </button>
        </div>
        <div class="key-value mono">
          <%= if @show_secret do %>
            <%= Application.get_env(:konet, :jwt_secret, "not set") %>
          <% else %>
            <%= @jwt_secret %>
          <% end %>
        </div>
        <div class="key-hint muted">Set via KONET_JWT_SECRET env var or konet.config.toml. Never rotate without regenerating all keys.</div>
      </div>
    </div>
    """
  end

  defp get_key_from_env(var), do: System.get_env(var)

  defp mask_secret(nil), do: "not set"
  defp mask_secret(""), do: "not set"
  defp mask_secret(s) when byte_size(s) <= 8, do: String.duplicate("*", byte_size(s))
  defp mask_secret(s) do
    visible = String.slice(s, 0, 4)
    "#{visible}#{String.duplicate("*", max(0, byte_size(s) - 4))}"
  end
end
