defmodule Konet.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # First: every named ETS table is created and owned here, so a worker
      # crashing no longer takes its data with it.
      Konet.Tables,
      {Phoenix.PubSub, name: Konet.PubSub},
      Konet.Presence,
      Konet.Metrics,
      Konet.ChannelRegistry,
      Konet.RateLimiter,
      Konet.Floor,
      Konet.LogBuffer,
      Konet.History,
      {Task.Supervisor, name: Konet.TaskSupervisor},
      KonetWeb.Telemetry,
      KonetWeb.Endpoint
    ]

    # The default restart intensity is 3 crashes in 5 seconds, which is tight
    # for a server whose workers are restartable by design: three unrelated
    # transient failures in one burst would take the whole node down and drop
    # every live socket. Now that Konet.Tables holds the data, a worker restart
    # costs almost nothing, so tolerate a burst — while still giving up on a
    # genuine crash loop, where dying and letting the container restart is the
    # right answer.
    opts = [
      strategy: :one_for_one,
      name: Konet.Supervisor,
      max_restarts: 10,
      max_seconds: 10
    ]

    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KonetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
