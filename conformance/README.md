# Conformance

Runs every SDK against a **real** `konet-server`, asserting the same scenario in
each language.

The gap this closes: the protocol is implemented four times, and until now each
implementation was verified only against its own mock. The server's tests pinned
the server's half, each SDK's tests pinned its own byte layout, and nothing ever
checked that the two halves agreed. A change to a reply shape would have been
caught by no test at all.

## What is asserted

The scenario is identical in every language. Each step is a claim about the
contract, not about one client's internals:

| # | Step | What it pins |
|---|---|---|
| 1 | connect with an anon token | the `/socket/websocket?token=…&vsn=2.0.0` path and query auth |
| 2 | join `room:<run-id>` | `phx_join` is accepted and replies `ok` |
| 3 | receive `presence_state` | the server pushes presence right after the join |
| 4 | client A broadcasts, B receives | the `"broadcast"` envelope `{event, payload}` unwraps to the inner event name |
| 5 | A receives its own broadcast | text broadcasts echo to their sender |
| 6 | A acquires the floor | `konet:floor_acquire` replies `{holder}` |
| 7 | both see `konet:floor` | the holder is announced to everyone, including the holder |
| 8 | B is refused the floor | `{reason: "floor_held", holder: "A"}` |
| 9 | A sends a binary frame, B receives it | the Phoenix v2 binary framing round-trips through a real server |
| 10 | A does **not** receive its own binary frame | `broadcast_from!` — no echo, or a phone hears itself at speaker volume |
| 11 | B's binary frame is refused | `{reason: "floor_required"}` |
| 12 | A releases, B can then acquire | the floor is transferable |
| 13 | a late joiner receives `konet:history` | replay shape `{messages: [{event, payload, timestamp}]}` |
| 14 | an unknown event is refused, channel survives | the catch-all `handle_in/3` does not kill the channel |
| 15 | a second socket of the **same user** shares the floor | the floor is keyed on the `sub` claim, not on the connection |

Steps 13 and 15 were covered by no test in any language.

Step 15 exists because writing this harness got it wrong first: both clients
initially used one token, so the "second holder is refused" step failed — the
second client *was* the first user, and `Konet.Floor` grants a duplicate press
by design. That is a real property of the contract, so it is now asserted in
both directions rather than worked around.

## Running it

```bash
./conformance/run.sh
```

It starts a server on port **4009** with its own secret, history enabled and
rate limits raised, runs each SDK in turn, and tears the server down. Exit code
is non-zero if any SDK fails any step.

To run a single SDK against an already-running server:

```bash
KONET_URL=ws://localhost:4000/socket KONET_TOKEN=<anon_key> \
  node conformance/js/conformance.mjs
```

## Adding a language

Implement the same numbered steps, print one `PASS <n> <name>` or
`FAIL <n> <name>: <why>` line per step, and exit non-zero on any failure.
`run.sh` only reads the exit code and echoes the output.
