defmodule KonetWeb.StudioComponents do
  @moduledoc "Shared UI pieces for the Studio LiveViews."
  use Phoenix.Component

  attr :open, :boolean, default: false
  attr :title, :string, required: true
  attr :on_close, :string, required: true
  slot :inner_block, required: true

  def detail_panel(assigns) do
    ~H"""
    <div :if={@open} class="detail-overlay" phx-click={@on_close}></div>
    <aside class={["detail-panel", @open && "detail-panel-open"]}>
      <div class="detail-panel-header">
        <h3 class="detail-panel-title mono"><%= @title %></h3>
        <button class="detail-panel-close" phx-click={@on_close}>×</button>
      </div>
      <div class="detail-panel-body">
        <%= render_slot(@inner_block) %>
      </div>
    </aside>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  def detail_row(assigns) do
    ~H"""
    <div class="detail-row">
      <span class="detail-row-label muted"><%= @label %></span>
      <span class="detail-row-value mono"><%= @value %></span>
    </div>
    """
  end

  attr :text, :string, required: true
  slot :inner_block, required: true

  def detail_section(assigns) do
    ~H"""
    <div class="detail-section">
      <h4 class="detail-section-title muted"><%= @text %></h4>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
