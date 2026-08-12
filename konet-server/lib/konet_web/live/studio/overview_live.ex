defmodule KonetWeb.Studio.OverviewLive do
  use KonetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Konet.PubSub, "studio:metrics")
    end

    metrics = Konet.Metrics.get()

    {:ok,
     assign(socket,
       page_title: "Overview",
       metrics: metrics,
       uptime: format_uptime(metrics.started_at)
     )}
  end

  @impl true
  def handle_info({:metrics_update, metrics}, socket) do
    {:noreply,
     assign(socket,
       metrics: metrics,
       uptime: format_uptime(metrics.started_at)
     )}
  end

  defp format_uptime(started_at) do
    diff = DateTime.diff(DateTime.utc_now(), started_at, :second)
    h = div(diff, 3600)
    m = div(rem(diff, 3600), 60)
    s = rem(diff, 60)
    "#{pad(h)}:#{pad(m)}:#{pad(s)}"
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <h2 class="page-title">Overview</h2>

      <div class="metrics-grid">
        <div class="metric-card">
          <div class="metric-label">Active Connections</div>
          <div class="metric-value accent"><%= @metrics.connections %></div>
        </div>
        <div class="metric-card">
          <div class="metric-label">Messages / sec</div>
          <div class="metric-value green"><%= @metrics.messages_rate %></div>
        </div>
        <div class="metric-card">
          <div class="metric-label">Total Messages</div>
          <div class="metric-value"><%= format_number(@metrics.messages_total) %></div>
        </div>
        <div class="metric-card">
          <div class="metric-label">Uptime</div>
          <div class="metric-value orange mono"><%= @uptime %></div>
        </div>
      </div>

      <div class="info-block">
        <div class="info-label">Server</div>
        <div class="info-row">
          <span class="muted">WebSocket</span>
          <span class="mono">ws://localhost:4000/socket</span>
        </div>
        <div class="info-row">
          <span class="muted">REST API</span>
          <span class="mono">http://localhost:4000/api</span>
        </div>
        <div class="info-row">
          <span class="muted">Version</span>
          <span class="mono">v<%= Konet.Version.current() %></span>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"
end
