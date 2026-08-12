# 02.5 — Metrics and telemetry

Three separate things share the word "metrics" in this codebase. They do not
talk to each other.

| | Source | Endpoint | Auth |
|---|---|---|---|
| Konet counters | `Konet.Metrics` GenServer | `GET /metrics` (Prometheus text), `GET /api/metrics` (JSON) | service key |
| Phoenix/VM/Konet telemetry | `KonetWeb.Telemetry` — `[:konet, :server]` every 10 s | **no reporter attached** | — |
| Studio tiles | `Konet.Metrics` over PubSub | `/studio/overview` | Studio password |

## `Konet.Metrics`

`lib/konet/metrics.ex`. A single GenServer holding four numbers plus a boot
timestamp:

```elixir
defstruct connections: 0,
          messages_total: 0,
          messages_rate: 0,
          messages_current_window: 0,
          started_at: nil
```

- `connection_opened/1` — cast from `UserSocket.connect/3` with the socket
  transport pid, which `Konet.Metrics` then monitors. There is no
  `connection_closed`: the `:DOWN` is the decrement.
- `message_sent/0` — cast from `RoomChannel` (text broadcast **and** binary
  frame), `AdminController.broadcast/2`, and `Studio.BroadcastLive`.
- A `:timer.send_interval(1_000, :compute_rate)` moves
  `messages_current_window` into `messages_rate` and zeroes the window, then
  broadcasts `{:metrics_update, state}` on `"studio:metrics"`.

**`connections` is owned by a monitor.** `connection_opened/1` takes the socket
transport pid, `Konet.Metrics` monitors it, and the count drops when that process
dies — whether it left cleanly, crashed or was killed. There is no matching
`connection_closed` to forget to call.

That replaced a pairing that could not hold: the increment fired once per socket
while the decrement fired once per **channel**, so a client in three rooms
decremented three times and the gauge drifted to zero on any multi-channel
workload — visibly wrong in the Studio tile, `konet_connections`, `/api/health`
and `konet status` simultaneously.

⚠️ **`messages_total` counts ingress, not egress.** One broadcast to a room of
500 subscribers counts as 1. That is the right number for rate-limiting
intuition and the wrong one for bandwidth planning.

## `GET /metrics` — Prometheus

`AdminController.prometheus/2` builds the exposition format by string
interpolation — no `prometheus_ex`, no `telemetry_metrics_prometheus`
dependency:

```
# HELP konet_connections Current WebSocket connections
# TYPE konet_connections gauge
konet_connections 12
# HELP konet_channels Active channels
# TYPE konet_channels gauge
konet_channels 3
# HELP konet_messages_total Messages broadcast since boot
# TYPE konet_messages_total counter
konet_messages_total 48210
# HELP konet_messages_per_second Messages broadcast in the last second
# TYPE konet_messages_per_second gauge
konet_messages_per_second 61
# HELP konet_uptime_seconds Seconds since boot
# TYPE konet_uptime_seconds counter
konet_uptime_seconds 8412
```

Served as `text/plain`. Five series, no labels, no histograms.

**The endpoint requires a service key.** `require_service_key/1` runs before
anything is rendered, so a Prometheus scrape config must carry the bearer token:

```yaml
scrape_configs:
  - job_name: konet
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials: <service_key>
    static_configs:
      - targets: ["konet.example.com"]
```

⚠️ This is an easy trap: most Prometheus setups assume `/metrics` is open, and
an unauthenticated scrape gets a `401` JSON body, not an empty exposition —
which some scrapers report as a parse error rather than an auth failure.

Note also that `konet_channels` is `length(ChannelRegistry.list())`, which
allocates the full list on every scrape. Harmless at realistic room counts.

## `GET /api/metrics` — JSON

Same numbers, JSON shape, same service-key requirement. This is what
`konet status` calls (`konet-cli/internal/api/client.go`, `Metrics/0`):

```json
{"connections": 12, "messages_total": 48210, "messages_per_second": 61,
 "uptime_seconds": 8412, "channels": 3}
```

## `GET /api/health` — the odd one out

The only **unauthenticated** route that exposes numbers:

```json
{"status": "ok", "version": "0.3.0", "connections": 12, "uptime_seconds": 8412}
```

It is unauthenticated because the Docker `HEALTHCHECK` in the image calls it
with `curl`, and because Coolify and Dokploy read it to show real health status.
Keep it that way, but be aware it publishes connection count and uptime to
anyone who can reach the port.

## `KonetWeb.Telemetry` — emitting, but unreported

`lib/konet_web/telemetry.ex` is a `Supervisor` running a `telemetry_poller`
plus a `metrics/0` listing Konet's own gauges (`konet.server.*`), the Phoenix
durations (endpoint, router dispatch, socket connect, channel join,
`channel_handled_in` by event) and the VM ones (memory, run queue lengths).

**The poller now emits, but no reporter is attached yet.**
`periodic_measurements/0` returns `{KonetWeb.Telemetry, :dispatch_server_metrics, []}`,
which executes `[:konet, :server]` every 10 s with `connections`, `channels`,
`messages_total` and `messages_per_second` — the same numbers `/metrics` serves,
available in-process without needing the service key. `metrics/0` declares
matching `last_value`/`counter` definitions alongside the Phoenix and VM ones.

What is left is attaching a reporter (`TelemetryMetricsPrometheus`,
`Telemetry.Metrics.ConsoleReporter`, …). It used to be dead scaffolding: no
reporter *and* an empty measurement list, so nothing was ever measured.
`phoenix.channel_handled_in.duration` tagged by `:event` is the one to watch —
it shows immediately whether the binary path is as cheap as claimed.

## What is deliberately not measured

- **Per-room metrics.** `ChannelRegistry` knows subscriber counts, but nothing
  exports them per room. The Studio Channels page reads the list live instead.
- **Egress bytes.** No byte counters anywhere, text or binary.
- **Floor activity.** `Konet.Floor` has no metrics; floor acquire/release show
  up only in `Konet.LogBuffer` (and therefore only in the Studio Logs page, last
  100 entries, lost on restart).
- **Webhook delivery success.** Failures go to `Logger.warning` only.
