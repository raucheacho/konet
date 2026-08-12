# 04.3 — `sdk/go` — `github.com/raucheacho/konet/sdk/go`

## Structure

```
sdk/go/
├── konet.go        Client — dial, read loop, heartbeat, reconnect, binary routing
├── channel.go      Channel — subscribe/send/binary/floor, reply channels
├── binary.go       Phoenix v2 binary framing
├── binary_test.go  byte-layout assertions for the wire format
├── client_test.go  reconnect, re-join, liveness, handler removal
├── go.mod          go 1.23 — single dependency: nhooyr.io/websocket v1.8.11
└── README.md
```

Package name is `konet`, so the import is
`konet "github.com/raucheacho/konet/sdk/go"`. Nothing is generated.

⚠️ `nhooyr.io/websocket` is the **archived** upstream of what is now
`github.com/coder/websocket`. It still works and is stable, but it receives no
updates. Migrating is a rename of the import path plus `wsjson` — worth doing
before it becomes a security question.

## `Client`

```go
type Client struct {
    url, token string
    mu               sync.RWMutex
    conn             *websocket.Conn
    channels         map[string]*Channel
    started          bool   // read/heartbeat loops are spawned once, not per reconnect
    pendingHeartbeat string // ref of the probe awaiting a reply, or ""
    refCounter       atomic.Uint64
    done             chan struct{}
    closeOnce        sync.Once
    opts             ClientOptions
}
```

`ClientOptions`: `HeartbeatInterval` (30 s), `ReconnectDelay` (1 s),
`MaxReconnectTries` (10), `HTTPHeader` (passed to the dial — the one place a Go
caller *can* use headers, unlike a browser).

Connection follows the same URL convention as every SDK:

```go
base := strings.TrimSuffix(c.url, "/")
wsURL := fmt.Sprintf("%s/websocket?token=%s&vsn=2.0.0", base, c.token)
```

The token goes through `url.QueryEscape`, matching JS's `encodeURIComponent`
and Python's `urlencode`. It used to be interpolated raw, which happens to work
for base64url JWTs but would break for any other token format.

### Read loop

`conn.Read` rather than `wsjson.Read`, deliberately: the opcode is what tells
text from binary, and `wsjson` would consume it and try to parse audio as JSON.

```go
messageType, message, err := conn.Read(ctx)
if messageType == websocket.MessageBinary { c.handleBinary(message); continue }
```

Text frames are decoded into `[]json.RawMessage` of length 5, then into
`phxFrame`. The `"phoenix"` topic is not dispatched to a channel, but its replies
are not thrown away either: a ref matching `pendingHeartbeat` clears the
outstanding probe, which is the SDK's liveness signal (see below).

### Binary routing

`handleBinary` decodes with `decodeServerBinaryFrame`, drops anything malformed,
ignores `binaryReply` (nothing waits on one, since `SendBinary` does not track
refs), and dispatches to the channel's `receiveBinary`.

## `Channel`

Handlers are split in two maps:

```go
handlers       map[string][]EventHandler   // func(payload interface{})
binaryHandlers map[string][]BinaryHandler  // func(data []byte)
```

kept apart because a binary event delivers `[]byte`, not a decoded payload, and
mixing them would force every handler to type-switch on something it already
knows. (The JS SDK made the opposite choice — see
[README.md](README.md#the-high-level-api-side-by-side).)

Replies use `map[string]chan interface{}` keyed by ref, so `Subscribe`,
`AcquireFloor` and `ReleaseFloor` all block on a channel receive with `ctx`
cancellation.

Two dispatch modes, and the asymmetry is intentional:

```go
// receive() — text
for _, h := range handlers { go h(frame.Payload) }

// receiveBinary() — binary
for _, h := range handlers { h(data) }   // synchronous
```

*"Synchronous, unlike receive: audio frames must reach the play-out buffer in
the order they arrived, and one goroutine per frame would not promise that."*

⚠️ The `BinaryHandler` contract is that the slice is **only valid for the
duration of the call** — it aliases the read buffer. Copy it to keep it.

Both `On` and `OnBinary` attach an explicit `id` (`eventSub` / `binarySub`) and
remove by that id, preserving registration order. `On` used to compare handlers
with `fmt.Sprintf("%p", h)` — Go gives no usable equality for funcs, and distinct
closures sharing a body share a code pointer — while `OnBinary` captured a slice
index that every earlier removal invalidated. Two tests cover it now.

## Reconnection

`readLoop` and `heartbeatLoop` are spawned **once**, by the first `Connect`, and
live across reconnects — `Client.started` guards that. Reconnection happens
inline in the read loop:

```go
messageType, message, err := conn.Read(ctx)
if err != nil {
    if !c.reconnect(ctx) { return }   // exhausted: end the loop
    continue
}
```

`reconnect` marks every channel closed, **closes the abandoned connection**,
backs off exponentially, dials, and then re-joins from a goroutine — inline
would deadlock, since `Subscribe` blocks on a reply that only the calling read
loop can deliver.

Three bugs this replaced, all now covered by `client_test.go`:

- **A heartbeat goroutine leaked per reconnect.** `Connect` used to spawn both
  loops every time; the old `readLoop` returned but the old `heartbeatLoop` only
  exits on `done`, which only `Disconnect` closes. After N reconnects the client
  sent N heartbeats per interval.
- **The abandoned connection was never closed.** Dropping the reference is not
  enough: the websocket library keeps a goroutine per connection until it is
  closed, so each reconnect leaked one. `CloseNow()` on the old conn fixes it.
- **`ch.state` was read and written without a lock** while `receive` and
  `Subscribe` touched it under one. CI now runs `go test -race`.

`Channel.wantsJoin` carries the caller's intent across drops, so `Unsubscribe`
means a channel is never silently re-joined, and `socketClosed` closes pending
reply channels so waiters get `ErrSocketClosed` rather than a 10 s stall.

### Liveness

`heartbeatLoop` records the outstanding probe in `Client.pendingHeartbeat` and
clears it in `handleText` when the reply arrives on the `"phoenix"` topic. If a
probe is still outstanding at the next tick, the connection is closed so the read
loop reconnects — detection stays in one place. Replies used to be discarded
with the rest of the `"phoenix"` topic, so a locally-open dead socket was never
noticed.

## Binary framing — `binary.go`

Same three shapes as every SDK. Go-specific details:

- `sizedField` returns an error (not a panic) above 255 bytes.
- `decodeServerBinaryFrame` returns `(BinaryFrame, error)` with a sentinel
  `ErrShortFrame`, and a `take(n)` closure that consumes bytes or reports the
  frame ended early.
- Error strings are in French (`"trame binaire tronquée"`,
  `"dépasse 255 octets"`), like the Python SDK.

`binary_test.go` asserts the byte layout directly, transcribed from Phoenix's
serializer rather than captured from a running server — the same table as
`sdk/js/src/__tests__/binary.test.ts` and `sdk/python/tests/test_binary.py`.

## `MarshalPayload`

```go
func MarshalPayload(raw interface{}, target interface{}) error {
    data, _ := json.Marshal(raw); return json.Unmarshal(data, target)
}
```

Exported helper for turning an `interface{}` payload into a typed struct. It
round-trips through JSON, so it is not cheap — fine for control events, not for
a hot path.

## Publishing

CI (job `sdk-go`) runs `go build`, `go vet` and `go test -race ./...`. The race
detector matters here: the client runs a read loop and a heartbeat loop against
shared channel state, and the reconnect path is exactly where that races. The
suite used to be absent from CI entirely.

Release (`release-sdk-go.yml`), on a `v*` tag: Go modules are served from the
VCS, so the job just verifies the module builds and then pushes a second tag:

```bash
set -euo pipefail
TAG="sdk/go/v${GITHUB_REF_NAME#v}"     # v0.3.0 → sdk/go/v0.3.0
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG is already published — nothing to do."; exit 0
fi
git tag "$TAG"
git push origin "$TAG"
```

The `sdk/go/` prefix is what the Go module proxy requires for a module living in
a subdirectory. Consumers then get it with:

```bash
go get github.com/raucheacho/konet/sdk/go@v0.3.0
```

A re-run is a no-op, but a genuine push failure (permissions, protected tags)
now fails the job. Both commands used to end in `|| echo`, which left the job
green with nothing published.

Note the module declares `go 1.23` while the CLI declares `go 1.25.0` — a lower
floor for the SDK is correct, since library consumers should not be forced onto
the newest toolchain.
