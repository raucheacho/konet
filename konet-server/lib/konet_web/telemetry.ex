defmodule KonetWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor: a poller that emits Konet's own gauges, plus the metric
  definitions a reporter can attach to.

  `metrics/0` used to be pure scaffolding — ten definitions with no reporter,
  next to a poller whose `periodic_measurements/0` returned an empty list, so
  nothing was ever measured or emitted. The poller now dispatches
  `[:konet, :server]` every 10 seconds, which means attaching a reporter
  (`TelemetryMetricsPrometheus`, `Telemetry.Metrics.ConsoleReporter`, …) is the
  only step left rather than the first of several.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Konet's own state, emitted by dispatch_server_metrics/0 below.
      last_value("konet.server.connections"),
      last_value("konet.server.channels"),
      last_value("konet.server.messages_per_second"),
      counter("konet.server.messages_total"),

      # Phoenix. channel_handled_in is tagged by event, which is what shows
      # whether the binary hot path is as cheap as it is meant to be.
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM.
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @doc """
  Emits the same numbers `/metrics` serves, as a telemetry event.

  Called by the poller, so a reporter sees them without polling the HTTP
  endpoint (which needs a service key, and is therefore awkward to scrape from
  inside the same node).
  """
  def dispatch_server_metrics do
    metrics = Konet.Metrics.get()

    :telemetry.execute(
      [:konet, :server],
      %{
        connections: metrics.connections,
        channels: length(Konet.ChannelRegistry.list()),
        messages_total: metrics.messages_total,
        messages_per_second: metrics.messages_rate
      },
      %{}
    )
  end

  defp periodic_measurements do
    [
      {__MODULE__, :dispatch_server_metrics, []}
    ]
  end
end
