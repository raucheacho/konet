# @raucheacho/konet-rn

React Native client for [Konet](https://github.com/raucheacho/konet), the
self-hosted realtime engine (channels, presence, broadcast).

A thin layer over [`@raucheacho/konet-js`](../js): the protocol is implemented
once, in the core, and this package adds the one thing React Native needs on
top of it — reacting to the app lifecycle.

## Install

```bash
npm install @raucheacho/konet-js @raucheacho/konet-rn
```

The core is a peer dependency, so there is a single copy of the protocol at
runtime and core fixes apply without republishing this package.

Konet releases every package in lockstep from a single git tag, so install both
at the same version. The peer range is deliberately `>=` rather than a caret:
`^0.2.0` would reject the 0.3.0 core that ships alongside a 0.3.0 of this
package.

No native module and no linking step: React Native provides the `WebSocket`
global the core builds on.

## Usage

```ts
import { createNativeClient } from '@raucheacho/konet-rn'

const client = createNativeClient('wss://konet.example.com/socket', {
  token: session.konetToken,
})

const map = client.channel('room:team-42:map')
await map.subscribe()

map.on('pos', (p) => updateMarker(p))
map.send('pos', { lat, lng, ts: Date.now() })
```

Everything else — channels, presence, send errors, options — is the core API.
See the [core README](../js/README.md).

## What this package adds

React Native suspends timers while an app is backgrounded. An app can come back
to the foreground believing it is connected long after the server timed the
socket out at 45s, because no close event ever fired in the frozen process.

`KonetNativeClient` subscribes to `AppState` and calls the core's
`checkConnection()` on every return to the foreground, which probes the socket
and reconnects if the probe goes unanswered. Channels are re-joined
automatically by the core.

That is the entire delta. If you already manage the lifecycle yourself, use
`KonetClient` from the core directly and call `checkConnection()` where it fits.

## Background execution

Keeping a socket alive while the app is backgrounded is an **app-level**
concern, not an SDK one, and the platforms differ sharply:

- **Android** — a foreground service keeps the process (and the socket) alive.
  Declare the service types you actually use (`location`, `microphone`), plus
  `FOREGROUND_SERVICE_MICROPHONE` on Android 14+.
- **iOS** — the OS suspends the app a few seconds after backgrounding and there
  is no general-purpose exemption for holding a socket open. Waking on incoming
  data requires a push: the PushToTalk framework (iOS 16+, needs the
  `com.apple.developer.push-to-talk` entitlement) for walkie-talkie apps, or
  PushKit + CallKit for call-shaped ones.

This SDK's job is to recover cleanly once your app runs again, which it does.

## Options

```ts
interface KonetNativeClientOptions extends KonetClientOptions {
  appState?: AppStateLike | null   // override or disable AppState wiring
}
```

`appState` defaults to React Native's `AppState`. Pass `null` to opt out of
foreground checks; pass your own implementation to drive the client from a
different lifecycle source (or in tests).

## License

MIT
