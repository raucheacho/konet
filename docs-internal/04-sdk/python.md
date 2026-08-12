# 04.4 — `sdk/python` — `konet`

## Structure

```
sdk/python/
├── konet/
│   ├── __init__.py   exports KonetClient, Channel, __version__
│   ├── client.py     KonetClient — connect, read loop, heartbeat, reconnect
│   ├── channel.py    Channel — subscribe/send/binary/floor, asyncio futures
│   └── binary.py     Phoenix v2 binary framing
├── tests/
│   ├── test_binary.py     wire-format assertions
│   └── test_reconnect.py  re-join, backoff, liveness
└── pyproject.toml    setuptools, requires-python >=3.10, deps: websockets>=12.0
```

Fully async (`asyncio`), single runtime dependency: `websockets`. Nothing is
generated. The PyPI package is named `konet` — it was renamed from `konet-py` in
commit `67a4263`, and the build backend was fixed from a non-existent
`setuptools.backends.legacy:build` to `setuptools.build_meta` in `2a320d1`.

## `KonetClient`

Designed around the async context manager:

```python
async with KonetClient("ws://localhost:4000/socket", token="kt_anon_…") as client:
    channel = client.channel("room:lobby")
    await channel.subscribe()
    channel.on("message", lambda p: print(p))
    await channel.send("message", {"text": "Hello!"})
    await asyncio.sleep(60)
```

`connect()` opens the socket and spawns two tasks, `_read_loop` and
`_heartbeat_loop`; `disconnect()` cancels them and closes.

URL construction matches every other SDK, with proper escaping:

```python
base = self._url.rstrip("/")
params = urlencode({"token": self._token, "vsn": "2.0.0"})
return f"{base}/websocket?{params}"
```

Binary vs text is decided by the type `websockets` hands back — `bytes` for a
binary frame, `str` for a text one. Malformed binary frames are dropped, not
raised: they must not take down the socket carrying every other channel.

## `Channel`

Same shape as the other SDKs, with `asyncio.Future` in place of Go's reply
channels:

- `_reply_futures: dict[str, asyncio.Future]` keyed by ref;
- `subscribe()` awaits with `asyncio.wait_for(fut, timeout=10.0)`;
- `_request()` backs `acquire_floor()` / `release_floor()`, same 10 s timeout,
  and raises `RuntimeError` with the server's refusal reason — including the
  holder's name on `floor_held`.
- Handlers may be sync or async: `_receive` checks
  `asyncio.iscoroutine(result)` and schedules with `asyncio.create_task`.
- `on_binary()` uses a separate `_binary_handlers` registry (same rationale as
  Go).

Error messages are in French (`"… sans réponse"`, `"refusé"`, `"détenue par …"`),
matching the Go SDK.

## Reconnection

This used to be the SDK's weak point and is now its most thoroughly tested part.
`KonetClient._reconnect` re-opens the socket with exponential backoff **and
restores the joins**:

```python
for channel in list(self._channels.values()):
    channel._socket_closed()      # state -> idle, pending replies fail
...
self._rejoin_task = asyncio.create_task(self._rejoin_channels())
```

Four things are worth knowing:

- **`_rejoin_channels` runs as a task, not inline.** A join awaits its reply, and
  that reply can only arrive through the read loop that called `_reconnect` —
  awaiting it inline deadlocks until the 10 s timeout.
- **`Channel._wants_join` is the caller's intent**, separate from `_state`. It
  survives socket drops and is cleared only by `unsubscribe()`, so a channel the
  application deliberately left is never silently re-joined.
- **`_socket_closed` fails pending replies** with `ConnectionError` instead of
  letting them sit on their 10 s timeout.
- **Giving up ends the read loop.** When `max_reconnect_tries` is exhausted,
  `_reconnect` returns False and `_read_loop` returns. It used to leave
  `self._ws = None` and spin at 10 Hz forever, awake and doing nothing.

### Liveness

`_heartbeat_loop` tracks `_pending_heartbeat_ref` and arms a
`heartbeat_timeout` (default 10 s) deadline. An unanswered probe closes the
socket, which makes `recv()` raise so reconnection stays in one place. The
probe is sent `heartbeat_timeout` before the end of each cycle, so the cadence
stays exactly `heartbeat_interval` (default 30 s, comfortably under the server's
45 s socket timeout) while detection happens within the timeout.

Replies on the `"phoenix"` topic used to be discarded with the rest of that
topic, so a socket that was open locally and dead server-side was never noticed.

## Binary framing — `binary.py`

Same three shapes, `BinaryFrame` as a frozen dataclass.
`decode_server_frame` returns `None` for anything malformed;
`encode_push` raises `ValueError` above 255 bytes per field.

The module docstring states the duplication policy explicitly:

> The same table appears in the JavaScript and Go SDKs. It is written out in
> each rather than shared, because a wire format is the one thing every client
> must agree on independently.

Decoding uses `.decode("utf-8", "replace")` for the header strings, so a
corrupt topic yields replacement characters and a dropped route rather than an
exception.

## Tests

- `tests/test_binary.py` (12) — the byte-layout assertions, transcribed from
  Phoenix's serializer, matching the JS and Go suites.
- `tests/test_reconnect.py` (7) — re-join after a drop, no re-join after
  `unsubscribe`, `send()` failing loudly while disconnected, pending replies
  failing instead of hanging, giving up rather than spinning, and both heartbeat
  liveness directions. Driven by a fake transport, so they pin the client's own
  state machine rather than the protocol.

They use `asyncio.run()` inside sync test functions rather than
`pytest-asyncio`, so bare `pytest` is enough.

CI runs them now — the `sdk-python` job does `pip install -e '.[dev]'`,
`compileall`, then `pytest -q`. It used to be `compileall` alone, which is a
syntax check and nothing more, so neither suite had ever run in CI.

## Publishing

Release (`release-sdk-python.yml`), on a `v*` tag:

```yaml
- run: pip install build
- name: Set version        # rewrites [project].version AND konet.__version__
  run: …                   # fails loudly if either anchor is missing
- run: python -m build
- uses: pypa/gh-action-pypi-publish@release/v1
  with:
    packages-dir: sdk/python/dist
```

Uses **PyPI trusted publishing** (`id-token: write`, no API token) — set up in
commit `e3f697c`. The repository must be registered as a trusted publisher on
PyPI for the `konet` project, tied to this workflow filename; renaming
`release-sdk-python.yml` breaks publishing.

The version step anchors on the `[project]` table and on `__version__`
explicitly, and fails the build if either is missing. It used to be a `sed` on
the first `version = ` line in the file, which only happened to be the right one
because `[build-system]` has no such key.

`konet/__init__.py`'s `__version__` is rewritten by the same step, so
`konet.__version__` matches the wheel. It used to be left at `0.1.0` on every
published release.
