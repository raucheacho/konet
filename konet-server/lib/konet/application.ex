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
      Konet.BinaryMode,
      Konet.LogBuffer,
      Konet.History,
      # Webhook deliveries get their own bounded pool, and the process that
      # schedules their retries.
      Konet.Webhooks.pool_spec(),
      Konet.Webhooks,
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

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      warn_if_studio_is_open()
      {:ok, pid}
    end
  end

  # The documentation says to set KONET_STUDIO_PASSWORD on anything reachable,
  # but nothing said so at runtime: a server deployed without it serves the
  # Studio to the world, silently. Only when the endpoint really listens, so
  # the test suite stays quiet.
  defp warn_if_studio_is_open do
    if Phoenix.Endpoint.server?(:konet, KonetWeb.Endpoint) and
         not Konet.Auth.studio_auth_enabled?() do
      require Logger

      Logger.warning(
        "konet: KONET_STUDIO_PASSWORD is not set — /studio is open to anyone who can " <>
          "reach this server (channels, presence, broadcast). Keys are hidden and " <>
          "rotation is disabled until it is set."
      )
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    KonetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
