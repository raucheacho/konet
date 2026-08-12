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
       rotated: false,
       rotation: nil,
       secret_file: Konet.Auth.secret_file(),
       show_secret: false
     )}
  end

  @impl true
  def handle_event("rotate", _, socket) do
    %{jwt_secret: secret, anon_key: anon, service_key: service} = result = Konet.Auth.rotate!()

    {:noreply,
     assign(socket,
       anon_key: anon,
       service_key: service,
       jwt_secret: mask_secret(secret),
       rotated: true,
       rotation: result
     )}
  end

  def handle_event("toggle_secret", _, socket) do
    {:noreply, assign(socket, show_secret: !socket.assigns.show_secret)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">API Keys</h2>
      <p class="subtitle muted">
        Anon key, service key, and JWT secret all come from one shared signing secret —
        rotating regenerates all three together. There's no way to invalidate just one of
        them without the others.
      </p>

      <%= if @rotated and @rotation.persisted do %>
        <div class="result-banner result-ok">
          Rotated and saved to <span class="mono"><%= @rotation.path %></span>. Every previously
          issued token just stopped working; this server will keep using the new secret after a
          restart. Make sure that path is on a volume that survives redeploys.
        </div>
      <% end %>

      <%= if @rotated and not @rotation.persisted and @rotation.error do %>
        <div class="result-banner result-err">
          Rotated, but writing <span class="mono"><%= @rotation.path %></span> failed:
          <%= @rotation.error %>. The new secret is live in this process only — copy the values
          below somewhere safe now, or a restart reverts to the old secret and locks out every
          client that stored the new anon key.
        </div>
      <% end %>

      <%= if @rotated and not @rotation.persisted and is_nil(@rotation.error) do %>
        <div class="result-banner result-err">
          Rotated — in memory only. Every previously issued token just stopped working, and
          <strong>a restart will revert to the old secret</strong>, locking out any client that
          stored the new anon key. Copy the values below into your env vars now, or set
          <span class="mono">KONET_SECRET_FILE</span> to a writable path so rotation persists
          by itself.
        </div>
      <% end %>

      <%= if not @rotated and (is_nil(@anon_key) or is_nil(@service_key)) do %>
        <div class="flash flash-info">
          No keys configured yet. Either run <span class="mono">konet keys generate</span> from
          your project (CLI), set the <span class="mono">KONET_ANON_KEY</span> /
          <span class="mono">KONET_SERVICE_KEY</span> env vars, or click
          <strong>Rotate Secret</strong> below to generate a fresh secret and both keys right now.
        </div>
      <% end %>

      <div class="key-card">
        <div class="key-header">
          <span class="key-label">Anon Key</span>
          <span class="badge badge-blue">public</span>
        </div>
        <div class="key-value mono">
          <%= if @anon_key, do: @anon_key, else: "Not configured" %>
        </div>
        <div class="key-hint muted">Use in client-side code. Grants access to public channels.</div>
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
        <div class="key-hint muted">
          Set via KONET_JWT_SECRET env var or konet.config.toml.
          <%= if @secret_file do %>
            Rotation persists to <span class="mono"><%= @secret_file %></span>.
          <% else %>
            <strong>Rotation is in-memory only</strong> — set
            <span class="mono">KONET_SECRET_FILE</span> to make it survive a restart.
          <% end %>
        </div>
      </div>

      <button class="btn btn-danger" phx-click="rotate" data-confirm="Rotate the JWT secret? Every anon/service key issued so far will stop working immediately.">
        Rotate Secret
      </button>
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
