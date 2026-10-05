# @raucheacho/konet-js

Type-safe JavaScript/TypeScript client for [Konet](https://github.com/raucheacho/konet),
the self-hosted realtime engine (channels, presence, broadcast). Works in
browsers and Node.js.

## Install

```bash
npm install @raucheacho/konet-js
```

## Usage

```ts
import { createClient } from '@raucheacho/konet-js'

const client = createClient('ws://localhost:4000/socket', {
  token: '<anon_key>',
})

const channel = client.channel('room:lobby')
await channel.subscribe()

channel.on('message', (payload) => console.log('Received:', payload))
channel.send('message', { text: 'Hello!' })
```

`createClient` connects immediately. Call `client.disconnect()` to close the socket.

## Options

```ts
interface KonetClientOptions {
  token: string
  heartbeatIntervalMs?: number   // default: 30000
  reconnectDelayMs?: number      // default: 1000
  maxReconnectAttempts?: number  // default: 10
  heartbeatTimeoutMs?: number    // default: 10000
}
```

`heartbeatTimeoutMs` is how long the client waits for a heartbeat reply before
declaring the socket dead. Keep it below the server's socket timeout (45s).

## Reconnection

The client reconnects with exponential backoff and **re-joins every channel you
subscribed to**, so a dropped connection is transparent to your code. A channel
you left with `unsubscribe()` is never re-joined. Delays are jittered so clients
dropped together do not reconnect in lockstep.

`client.onStatus((status) => …)` reports `connecting`, `connected`,
`reconnecting` (with `attempt` and `delayMs`), `disconnected` and `failed` (the
reconnect attempts are used up). It returns a function that removes the handler.

While disconnected, `send()` throws instead of writing into a socket the server
no longer associates with your topic — a failed send is always visible.

After a re-join the server replays `presence_state`, so `getPresence()` is
accurate again without any action on your part.

## Send errors

Konet acknowledges a broadcast only when it **refuses** it (rate limiting, an
unsupported payload). There is no ack on success, so `send()` stays
fire-and-forget rather than returning a promise that could never settle.

Refusals surface two ways — per call, and per channel:

```ts
channel.send('audio', chunk, (err) => {
  console.warn('dropped:', err.reason)   // e.g. "rate_limited"
})

channel.on('send_error', (err) => metrics.increment(err.reason))
```

```ts
interface KonetSendError {
  topic: string
  event: string      // the application event you passed to send()
  payload: unknown
  reason: string     // server-supplied, e.g. "rate_limited"
}
```

This matters most on high-frequency streams (audio, telemetry), where the
server's per-socket rate limit is reached silently otherwise. Raise it with
`KONET_RATE_LIMIT` on the server if you see `rate_limited` under normal load.

## Suspended environments

`setInterval` is a scheduler, not a clock: browsers throttle timers in inactive
tabs and mobile runtimes freeze them outright. A suspended client can wake up
with a socket that still reports `OPEN` long after the server timed it out.

Call `checkConnection()` whenever your host may have suspended the client. It
probes the connection and reconnects if the probe goes unanswered — and revives
a client that exhausted `maxReconnectAttempts` while suspended.

```ts
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) client.checkConnection()
})
```

In React Native, use [`@raucheacho/konet-rn`](../react-native), which wires this
to `AppState` for you.

## Binary frames

For audio or anything else at a media rate. Each topic runs one of two modes,
chosen at join; every member of a topic must ask for the same one.

```ts
// Push-to-talk — "exclusive", the default: one sender at a time, by floor.
const ptt = client.channel('room:team-42:ptt')
await ptt.subscribe()
await ptt.acquireFloor()            // if taken: KonetRequestError, .holder names them
ptt.sendBinary('a', frame)          // frame: Uint8Array, copied
await ptt.releaseFloor()
ptt.on('konet:floor', ({ holder }) => { /* user id, or null when free */ })

// A call — "multiplex": everyone sends at once, no floor.
const call = client.channel('room:call-7', { binaryMode: 'multiplex' })
await call.subscribe()
call.on('a', (data, sender) => { /* sender: who sent this frame */ })
call.sendBinary('a', frame)

// A refused frame (no floor, rate limited), at most once per reason per second.
call.on('binary_error', (e) => { /* { topic, reason } */ })
```

A join asking for the other mode than the topic's members is refused with
`binary_mode_mismatch`; a multiplex topic beyond the server's member ceiling,
with `topic_full`. Frames are never echoed to their sender and never buffered
across a reconnect. Details: [binary frames](https://raucheacho.github.io/konet/reference/binary).

## Presence

```ts
channel.on('presence', (users) => console.log('Online:', users.length))

// or read the current snapshot
const users = channel.getPresence().list()
```

## License

MIT
