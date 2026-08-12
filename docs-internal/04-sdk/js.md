# 04.1 — `sdk/js` — `@raucheacho/konet-js`

The reference implementation. Everything the other SDKs do is a subset of what
happens here, and the React Native package literally reuses it.

## Structure

```
sdk/js/
├── src/
│   ├── index.ts       public surface + createClient()
│   ├── client.ts      KonetClient — socket, heartbeat, reconnect, frame routing
│   ├── channel.ts     Channel — join/leave, send, binary, floor, reply tracking
│   ├── presence.ts    Presence — folds presence_state/presence_diff into a map
│   ├── binary.ts      Phoenix v2 binary framing (encode push / decode server frame)
│   └── __tests__/     client.test.ts, binary.test.ts, mock-socket.ts
├── package.json       tsup build, vitest, typescript — no runtime dependency
└── tsconfig.json      ES2017, strict, lib ["ES2017", "DOM"]
```

**Zero runtime dependencies.** It uses the platform `WebSocket`, `TextEncoder`
and `TextDecoder` globals. Nothing is generated; `dist/` is produced by tsup at
publish time and gitignored.

## `KonetClient` — what it actually solves

`client.ts` is where the hard-won behaviour lives. Five problems, each with its
own machinery:

### 1. The transport path

```ts
const base = this.url.replace(/\/$/, "");
const wsUrl = `${base}/websocket?token=${encodeURIComponent(this.opts.token)}&vsn=2.0.0`;
```

Phoenix mounts the actual WebSocket at `<socket path>/websocket`, not at the
socket path. All four SDKs carry the same comment.

### 2. Re-joining after a reconnect

The server knows nothing about the topics a client had joined on a previous
socket. `onopen` re-issues `phx_join` for every channel **before anything else
goes out**:

```ts
ws.onopen = () => {
  if (this.ws !== ws) return;        // a forced reconnect superseded this socket
  this.state = "connected";
  for (const ch of this.channels.values()) ch._rejoin();
  this.startHeartbeat();
  this.flushSendBuffer();
};
```

and `onclose` marks every channel as no longer joined:

```ts
for (const ch of this.channels.values()) ch._socketClosed();
this.sendBuffer = [];   // buffered frames carry join refs from the dead socket
```

`Channel._rejoin()` only fires when `wantsJoin` is set — a channel the caller
explicitly `unsubscribe()`d is never silently re-joined. Covered by four tests
in `describe("reconnect")`, including *"does not re-join a channel that was
explicitly left"*.

> This is the fix for the reconnect/re-join problem that used to bite this SDK.
> It is done and tested; the equivalent is **missing in the Python SDK** and
> only partly present in Go — see [python.md](python.md) and [go.md](go.md).

### 3. Sockets that are dead but do not know it

The subtle case: React Native suspends timers in the background, browsers
throttle inactive tabs. A socket can stay locally `OPEN` long after the server's
45 s timeout dropped it, with no `close` event ever firing.

Three mechanisms, layered:

- **A heartbeat with a deadline.** `sendHeartbeat()` sends
  `[null, ref, "phoenix", "heartbeat", {}]`, records `pendingHeartbeatRef`, and
  arms a `heartbeatTimeoutMs` (default 10 s) timer that calls `forceReconnect()`
  if no reply arrives. The reply is matched by ref in `handleFrame` — the
  `"phoenix"` topic is not discarded as noise, it *is* the liveness signal.
- **Wall-clock validation of the interval.** `onHeartbeatTick()` compares
  `Date.now()` against `lastTickAt`; if more than 2× the interval elapsed, the
  timer was suspended and it calls `checkConnection()` instead of blindly
  pinging. *"setInterval is a scheduler, not a clock."*
- **`checkConnection()`, public.** Call it whenever the host environment may
  have suspended the client. It reconnects immediately if a probe was already
  outstanding, reconnects if the socket is not `OPEN`, revives a client that
  exhausted `maxReconnectAttempts`, and otherwise sends a fresh probe. This is
  the single hook the React Native package needs.

`forceReconnect()` nulls `this.ws` *before* closing the old socket, so the old
socket's `onclose` hits its `if (this.ws !== ws) return` guard and cannot
schedule a second reconnect.

### 4. Buffering, and what is deliberately not buffered

```ts
private sendFrame(frame: PhxFrame): void {
  if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(frame));
  else this.sendBuffer.push(frame);
}
```

Text frames racing the initial connect are buffered and flushed on `onopen`.
Joins deliberately never take this path — they are issued from `onopen` so
first-connect and reconnect follow the same code.

`sendBinary` is the opposite: **dropped outright** when the socket is not open.
Replaying audio recorded seconds ago into a live channel is worse than losing
it.

### 5. Reconnect backoff

`scheduleReconnect()` — `reconnectDelayMs * 2^attempts`, capped at 30 s, up to
`maxReconnectAttempts` (default 10). After that the client gives up until
`checkConnection()` revives it.

### Options

```ts
{
  token: string,                    // required
  heartbeatIntervalMs?: 30_000,
  reconnectDelayMs?: 1_000,
  maxReconnectAttempts?: 10,
  heartbeatTimeoutMs?: 10_000,      // keep below the server's 45s socket timeout
}
```

## `Channel`

State machine: `idle → joining → joined`, plus `errored` and `leaving`.
`wantsJoin` is tracked separately from `state` — it is the caller's *intent*,
survives socket drops, and is cleared only by `unsubscribe()`.

Notable behaviours:

- **`subscribe()` is safe before the socket is open.** It sets `wantsJoin`,
  registers a waiter promise, and only sends the join if `isOpen()`. Otherwise
  `onopen` will.
- **A refused join keeps `wantsJoin` set** — a rejection is often a stale or
  expired token, and the next reconnect should retry with whatever token the
  client holds by then.
- **`send()` throws when not joined**, rather than silently dropping.
- **Refusals are surfaced twice.** `trackSend` registers a one-shot reply
  handler under `phx_reply:<ref>`; on a non-ok status it calls the per-call
  `onError` *and* emits a channel-level `"send_error"` event carrying
  `{topic, event, payload, reason}`. Since the server never acks a success, the
  tracker self-expires after `SEND_REPLY_GRACE_MS` (10 s).
- **`request()`** is the private request/reply helper backing `acquireFloor()`
  and `releaseFloor()`. Same 10 s timeout. Its rejection messages are in French
  (`"… sans réponse"`, `"refusé"`) — the codebase mixes languages here.
- **`_socketClosed()` drops in-flight send trackers rather than failing them.**
  A send whose socket died is indistinguishable from one that was accepted, so
  inventing a failure would be wrong.

## `binary.ts`

Implements the three Phoenix v2 binary shapes. See
[../02-konet-server/02-binary-and-floor.md](../02-konet-server/02-binary-and-floor.md#wire-format)
for the layout. Two details specific to this file:

- `sized()` throws `RangeError` above 255 bytes rather than truncating, because
  a silently truncated topic would deliver audio to the wrong room.
- `decodeServerFrame` returns `null` on anything malformed instead of throwing —
  a bad frame must not take down the socket carrying every other channel.
- `ws.binaryType = "arraybuffer"` is set in `openSocket()`: a `Blob` would force
  an async round trip per frame, 50 times a second, for nothing.

## Tests

`vitest`, 26 tests — 17 in `client.test.ts`, 9 in `binary.test.ts` — driven by a
hand-written `MockWebSocket` (`src/__tests__/mock-socket.ts`) that can simulate
server replies, an abrupt drop, and a socket that stays `OPEN` while nothing
answers.

Groups: `join lifecycle`, `reconnect`, `send errors`, `heartbeat`,
`checkConnection`, `presence`.

The binary tests are written in French, matching the Go and Python suites.

## Publishing

CI (`.github/workflows/ci.yml`, job `sdk-js`): `npm ci` → `typecheck` →
`test` → `build`.

Release (`.github/workflows/release-sdk-js.yml`), on any `v*` tag:

```bash
npm version ${GITHUB_REF_NAME#v} --no-git-tag-version
npm ci
npm run build          # tsup src/index.ts --format cjs,esm --dts
npm publish --access public   # NODE_AUTH_TOKEN = secrets.NPM_TOKEN
```

⚠️ Note the order: `npm version` runs **before** `npm ci`. It works because
`npm version` only rewrites `package.json`/`package-lock.json` version fields,
but it means the lockfile is modified before `npm ci` validates it. `npm ci`
tolerates a version-only mismatch; a stricter npm release could break this.

The `version` field committed in `package.json` (`0.1.0`) is therefore
irrelevant — the tag is the source of truth.
