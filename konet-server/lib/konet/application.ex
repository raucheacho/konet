defmodule Konet.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Konet.PubSub},
      Konet.Presence,
      Konet.Metrics,
      Konet.ChannelRegistry,
      Konet.RateLimiter,
      Konet.LogBuffer,
      Konet.History,
      {Task.Supervisor, name: Konet.TaskSupervisor},
      KonetWeb.Telemetry,
      KonetWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Konet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KonetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
