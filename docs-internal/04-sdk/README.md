# 04 — SDKs

| File | Package |
|---|---|
| [js.md](js.md) | `@raucheacho/konet-js` — **the reference implementation** |
| [react-native.md](react-native.md) | `@raucheacho/konet-rn` |
| [go.md](go.md) | `github.com/raucheacho/konet/sdk/go` |
| [python.md](python.md) | `konet` (PyPI) |

## The shared contract

There is **no schema, no IDL, no code generation**. Nothing is generated in any
SDK — every line is hand-written. The contract is the Phoenix Channels v2
protocol plus a small set of Konet conventions, and it is enforced in three
places:

1. **The server tests** (`konet-server/test/konet_web/room_channel_test.exs`) —
   they pin the server's half: which events exist, what a refusal looks like,
   that binary frames need the floor.
2. **A binary-framing test in each SDK** — `sdk/js/src/__tests__/binary.test.ts`,
   `sdk/go/binary_test.go`, `sdk/python/tests/test_binary.py`. All three carry
   the same assertions, transcribed from Phoenix's serializer rather than
   captured from a running server. The comment at the top of each says why:
   *"they state the byte layout rather than agree with whatever the code
   currently emits"*.
3. **Nothing else.** There is no cross-SDK conformance suite, no integration
   test that runs a real server against a real client. If the server changes a
   reply shape, only the server tests catch it — the SDKs will drift silently.

### The high-level API, side by side

The four SDKs are intentionally shaped the same, adapted to each language's
idiom:

| Concept | JS / RN | Go | Python |
|---|---|---|---|
| create + connect | `createClient(url, {token})` | `konet.New(url, token)` + `Connect(ctx)` | `KonetClient(url, token=…)` as async ctx manager |
| get a channel | `client.channel("room:x")` | `client.Channel("room:x")` | `client.channel("room:x")` |
| join | `await ch.subscribe()` | `ch.Subscribe(ctx)` | `await ch.subscribe()` |
| leave | `ch.unsubscribe()` | `ch.Unsubscribe()` | `await ch.unsubscribe()` |
| listen | `ch.on(event, fn)` → unsubscribe fn | `ch.On(event, fn)` → func() | `ch.on(event, fn)` → callable |
| broadcast | `ch.send(event, payload, onError?)` | `ch.Send(event, payload)` | `await ch.send(event, payload)` |
| binary listen | `ch.on(event, fn)` (receives `Uint8Array`) | `ch.OnBinary(event, fn)` | `ch.on_binary(event, fn)` |
| binary send | `ch.sendBinary(event, data)` | `ch.SendBinary(event, data)` | `await ch.send_binary(event, data)` |
| take the floor | `await ch.acquireFloor()` → holder | `ch.AcquireFloor(ctx)` → holder | `await ch.acquire_floor()` → holder |
| release | `await ch.releaseFloor()` | `ch.ReleaseFloor(ctx)` | `await ch.release_floor()` |
| presence | `ch.getPresence()` → `Presence` class, `on("presence", …)` | `ch.On("presence_state" / "presence_diff", …)` — raw | same as Go — raw |

Deliberate divergences:

- **Only the JS SDK has a `Presence` class.** `sdk/js/src/presence.ts` folds
  `presence_state`/`presence_diff` into a map and emits a synthetic
  `"presence"` event. Go and Python hand you the raw Phoenix events; the caller
  does the folding.
- **Binary delivery differs.** JS routes binary frames through the same
  `on(event, …)` handlers as text (`_receiveBinary` calls `emit`), so a handler
  may receive either a decoded payload or a `Uint8Array`. Go and Python keep two
  registries (`binaryHandlers` / `_binary_handlers`) so a handler never has to
  type-check something it already knows.
- **Error surfacing on `send()`.** Only the JS SDK tracks refusals: it exposes
  an optional `onError` callback per call *and* a channel-level `"send_error"`
  event. Go and Python fire and forget; a `rate_limited` refusal is silently
  dropped.
- **Reconnection maturity is now comparable.** JS, Go and Python all re-issue
  `phx_join` after a reconnect, keep the caller's intent separate from channel
  state so an explicit leave is never undone, fail in-flight requests instead of
  stalling them, and detect a socket that is open locally but dead server-side
  from an unanswered heartbeat. Go and Python were missing every one of those.

### Konet conventions layered on top of Phoenix

These are what an SDK author has to know beyond "speak Channels v2":

| Convention | Detail |
|---|---|
| Transport path | Phoenix mounts the socket at `<path>/websocket`. All four SDKs append it and add `?token=…&vsn=2.0.0`. Getting this wrong is the classic first bug. |
| Auth | token in the **query string**, not a header — browsers cannot set headers on a `WebSocket`. |
| Broadcast envelope | client sends event `"broadcast"` with payload `{event, payload}`; the server re-broadcasts under the inner `event` name. |
| No ack on success | an accepted broadcast produces no `phx_reply`. Only refusals reply. |
| Echo | text broadcasts come back to their sender; **binary frames do not** (`broadcast_from!`). |
| Floor events | `konet:floor_acquire` / `konet:floor_release` are request/reply; `konet:floor` is a server broadcast carrying `{holder, since}`. |
| History | a single `konet:history` push right after join, payload `{messages: [{event, payload, timestamp}]}`. |
| Heartbeat | `[null, ref, "phoenix", "heartbeat", {}]`; the server socket times out at 45 s. |
| Binary frames are never buffered | every SDK drops binary sends while the socket is down, on purpose: replaying audio recorded seconds ago is worse than losing it. |

### Where the contract is *not* verified

Worth being blunt about, since it is the main risk in this area:

This used to be the largest risk in the codebase: the protocol was implemented
four times and verified against four separate mocks, so a change to a reply
shape would have been caught by no test at all.

[`conformance/`](../../conformance/) closes it. One `konet-server`, one scenario,
run by the JS, Go and Python SDKs — 15 steps each, in CI. It covers the two
things no SDK's own tests ever asserted: the `konet:history` payload shape, and
that the floor is keyed on the `sub` claim rather than on the connection.

What is still not covered:

- **React Native**, which needs an RN runtime. It is a thin subclass of the JS
  core, and the protocol it speaks *is* covered.
- **Reply shapes in isolation.** Each SDK's own unit tests still assert only its
  byte layout; the cross-checking lives in the harness.

CI runs every suite, including `go test -race` for `sdk/go`, `pytest` for
`sdk/python` and the conformance harness; until recently it ran none of those
three.

## Publishing a new version

All four are published by the same tag — see
[../03-konet-cli/02-release-goreleaser.md](../03-konet-cli/02-release-goreleaser.md#one-tag-releases-everything).
Per-package details are in each file below.
