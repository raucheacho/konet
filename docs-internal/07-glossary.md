# 07 — Glossary

Konet-specific vocabulary, plus the Phoenix terms it inherits. Each entry says
where the concept actually lives in the code.

---

**anon key** — A JWT with `{"role": "anon"}` signed with `KONET_JWT_SECRET`,
meant to be embedded in client-side code. It is not a distinct credential type:
the server only sees the `role` claim. Grants no admin access, and by default
may join **any** room (see *scoped token*). Minted by `konet keys generate`,
`Konet.Auth.rotate!/0`, or by hand.
→ `konet-cli/cmd/keys.go`, `lib/konet/auth.ex`

**binary frame** — A WebSocket message carrying raw bytes instead of JSON, using
Phoenix Channels v2's own framing (three shapes, distinguished by the first
byte). Konet uses them for media-rate payloads — audio, telemetry — because
base64-inside-JSON costs a third of overhead plus a parse every 20 ms. Refused
unless the sender holds the channel's *floor*, never recorded in *history*,
never logged, and never echoed back to the sender.
→ `lib/konet_web/room_channel.ex` (`handle_in/3` with `{:binary, data}`),
`sdk/*/binary.{ts,go,py}`

**broadcast** — Konet's core operation: a client sends the event
`"broadcast"` with payload `{event, payload}`, and the server re-emits it to
every subscriber of the topic under the inner `event` name. Ephemeral by
default. **An accepted broadcast is never acknowledged** — only refusals produce
a `phx_reply`. Delivered back to its own sender (unlike a binary frame).
→ `RoomChannel.handle_in("broadcast", …)`

**channel** — Two meanings, and the ambiguity is real:
1. *Phoenix channel* — the server-side process handling one client's
   subscription to one topic. Konet has exactly one, `KonetWeb.RoomChannel`,
   routed from `channel "room:*"`.
2. *Konet channel* — what the SDKs and the Studio call a room: `client.channel("room:lobby")`.
The REST API and the CLI use the second sense (`GET /api/channels` returns rooms
with subscriber counts).

**channel_occupied / channel_vacated** — Webhook events fired when a room's
subscriber count reaches 1 and drops to 0 respectively. Emitted from
`Konet.ChannelRegistry`, not from the channel itself, because only the registry
knows the count.
→ `lib/konet/channel_registry.ex`

**fastlane** — A Phoenix optimisation Konet depends on: `broadcast!` with a
`{:binary, _}` payload encodes the frame once and writes it directly into every
subscriber's socket, bypassing their channel processes. This is the single
biggest technical reason the server is Phoenix rather than Node or Go.

**floor / floor control** — Exclusive speaking rights on a topic: at most one
member holds the floor at a time, and a second sender is *told no* rather than
mixed in. The primitive behind half-duplex media (push-to-talk, a radio net, a
turn-based game). Konet arbitrates who may send; it does not know what is being
sent. Acquisition is atomic (`:ets.insert_new/2` as a compare-and-swap), and
release is guaranteed three ways: explicit release, a process monitor on the
holder, and a sweep after `KONET_FLOOR_MAX_HOLD_MS`.
→ `lib/konet/floor.ex`

**floor_held** — The refusal reason returned by `konet:floor_acquire` when
someone else holds the floor. The reply names them: `{reason: "floor_held",
holder: "alice"}`, so a UI can say *who* is talking.

**floor_required** — The refusal reason returned for a binary frame sent without
holding the floor.

**`konet:floor`** — The server broadcast announcing a floor change, payload
`{holder: user_id | nil, since: ms}`. Sent to **everyone including the new
holder**: subscribers need to know a stream is starting before its first frame
arrives, and the holder needs the same id to stamp its frames with.

**`konet:history`** — The single push a client receives just after joining, when
history replay is enabled, carrying `{messages: [{event, payload, timestamp}]}`
oldest-first.

**heartbeat** — The keep-alive every SDK sends on the reserved `"phoenix"`
topic: `[null, ref, "phoenix", "heartbeat", {}]`. The server's socket timeout is
45 s (`endpoint.ex`), so SDKs default to a 30 s interval. In the JS SDK the
*reply* is the liveness signal — a probe that goes unanswered within
`heartbeatTimeoutMs` forces a reconnect. The Go and Python SDKs send heartbeats
but discard the replies, so they have no liveness detection.

**history / replay buffer** — An optional in-memory ring of the last
`KONET_HISTORY_LIMIT` broadcasts per room, pushed to late joiners as
`konet:history`. **Off by default** (`0`). Deliberately not durable storage:
everything is in ETS and lost on restart. It exists so an agent can broadcast
into an empty room and a client connecting seconds later still sees it, without
Konet growing a database.
→ `lib/konet/history.ex`

**join_ref** — The Phoenix v2 wire field identifying which *join* a frame
belongs to. Distinct from `ref`, which identifies an individual request. After a
reconnect the join_ref changes, which is how a client detects replies from a
join a reconnect already superseded.

**member_joined / member_left** — Webhook events fired on every channel join and
every channel teardown, carrying `{room, user}`. Unlike
`channel_occupied`/`vacated`, they fire per member, not per room transition.

**presence** — Who is currently in a room, tracked by `Phoenix.Presence` (a
CRDT). Konet adds nothing to it beyond fixing the metadata shape server-side:
`%{online_at, room, role}`. **A client cannot attach its own presence metadata** —
no display name, avatar or colour. The intended workaround (shown in
`examples/live-room`) is to carry identity inside broadcast payloads.
Clients receive `presence_state` (a full snapshot, once after join) and
`presence_diff` (incremental, from Phoenix). Only the JS SDK folds them into a
map for you.
→ `lib/konet/presence.ex`, `sdk/js/src/presence.ts`

**room** — A topic under the `room:` namespace. `room_id` is everything after
the first colon, so `"room:tenant-7:inbox"` has `room_id = "tenant-7:inbox"`.
Note the two identifiers that coexist: `socket.topic` is the full `"room:lobby"`
(used as the `Konet.Floor` key), `socket.assigns.room_id` is the bare `"lobby"`
(used by the registry, history, webhooks and the Studio).

**scoped token** — A JWT carrying a `channels` claim: a list of topics the token
may join. Entries may end in `*` for prefix matching (`"room:user-42:*"` covers
a whole namespace with one token). **Only a trailing wildcard works** — an
interior `*` matches nothing. A token *without* a `channels` claim may join any
room, which is what keeps the shared anon/service keys working.
→ `RoomChannel.authorized?/2`, `topic_allowed?/2`

**service key** — A JWT with `{"role": "service"}`. Required by every `/api/*`
admin route and by `/metrics`, as `Authorization: Bearer <service_key>`.
Server-side only — it grants broadcast-into-any-room and read-all-presence.

**socket_id** — 16 random bytes, hex-encoded, generated per WebSocket
connection. Used as the rate-limiter bucket key and as `UserSocket.id/1`
(`"user_socket:<socket_id>"`, which would allow force-disconnecting one socket —
nothing uses that today).

**Studio** — The LiveView admin dashboard at `/studio`, served by the Konet
server itself on the same port (there is deliberately no separate listener).
Seven pages: Overview, Channels, Presence, Logs, Broadcast, Keys. Protected by
`KONET_STUDIO_PASSWORD` — **and an unset password means no login at all**, not
that it is disabled.
→ `lib/konet_web/live/studio/`

**topic** — The Phoenix string identifying a subscription, e.g. `"room:lobby"`.
Konet routes exactly one pattern, `"room:*"`. `"phoenix"` is reserved for the
heartbeat.

**vsn=2.0.0** — The serializer version every SDK appends to the WebSocket URL,
selecting Phoenix's v2 wire format (the 5-element array plus the binary framing).
Omitting it gets you v1, whose frames are a JSON object and whose binary
support differs.

**`/socket/websocket`** — The real transport path. Phoenix mounts the socket at
`/socket` but the WebSocket endpoint lives one segment deeper. Every SDK appends
`/websocket` and every SDK carries the same comment about it — getting this
wrong is the classic first bug when writing a new client.
