"""Conformance scenario — Python SDK against a real konet-server.

See ../README.md for the numbered steps.
"""

from __future__ import annotations

import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sdk", "python"))

from konet import KonetClient  # noqa: E402

URL = os.environ.get("KONET_URL", "ws://127.0.0.1:4009/socket")
TOKEN = os.environ.get("KONET_TOKEN")
# A second *identity*, not just a second socket: the floor is keyed on the user
# id from the "sub" claim, so two connections sharing a token count as one
# holder.
TOKEN_B = os.environ.get("KONET_TOKEN_B") or TOKEN
ROOM = os.environ.get("KONET_ROOM", f"room:conf-py-{int(time.time() * 1000)}")

failures = 0


def _pass(n: int, name: str) -> None:
    print(f"PASS {n} {name}")


def _fail(n: int, name: str, why: str) -> None:
    global failures
    failures += 1
    print(f"FAIL {n} {name}: {why}")


def check(n: int, name: str, ok: bool, why: str = "condition was false") -> None:
    _pass(n, name) if ok else _fail(n, name, why)


class Waiter:
    """Collects payloads for one event so a test can await the first."""

    def __init__(self) -> None:
        self.queue: asyncio.Queue = asyncio.Queue()

    def deliver(self, payload) -> None:
        self.queue.put_nowait(payload)

    async def wait(self, timeout: float = 3.0):
        try:
            return await asyncio.wait_for(self.queue.get(), timeout)
        except asyncio.TimeoutError:
            return None


def watch(channel, event: str) -> Waiter:
    waiter = Waiter()
    channel.on(event, waiter.deliver)
    return waiter


def watch_binary(channel, event: str) -> Waiter:
    waiter = Waiter()
    channel.on_binary(event, lambda data: waiter.deliver(bytes(data)))
    return waiter


def history_shape_ok(payload) -> bool:
    """The replay payload shape, which no SDK's own tests cover in any language."""
    if not isinstance(payload, dict):
        return False
    messages = payload.get("messages")
    if not isinstance(messages, list) or not messages:
        return False
    return all(
        isinstance(m, dict)
        and isinstance(m.get("event"), str)
        and isinstance(m.get("timestamp"), str)
        and "payload" in m
        for m in messages
    )


async def main() -> None:
    if not TOKEN:
        print("KONET_TOKEN is required", file=sys.stderr)
        sys.exit(2)

    # 1 — connect
    a = KonetClient(URL, token=TOKEN, max_reconnect_tries=3)
    b = KonetClient(URL, token=TOKEN_B, max_reconnect_tries=3)
    await a.connect()
    await b.connect()
    _pass(1, "connect")

    try:
        ch_a = a.channel(ROOM)
        ch_b = b.channel(ROOM)

        # Registered before the join: the presence push follows it immediately.
        presence = watch(ch_a, "presence_state")

        # 2 — join
        await ch_a.subscribe()
        await ch_b.subscribe()
        _pass(2, "join")

        # 3 — presence
        check(3, "presence_state", await presence.wait() is not None, "no presence_state within 3s")

        # 4/5 — broadcast reaches the other client, and echoes to the sender
        on_b = watch(ch_b, "conf:hello")
        on_a = watch(ch_a, "conf:hello")
        await ch_a.send("conf:hello", {"n": 42})

        got_b = await on_b.wait()
        check(4, "broadcast reaches other client", isinstance(got_b, dict) and got_b.get("n") == 42, str(got_b))

        got_a = await on_a.wait()
        check(5, "broadcast echoes to sender", isinstance(got_a, dict) and got_a.get("n") == 42, str(got_a))

        # 6/7 — floor granted and announced to everyone
        floor_a = watch(ch_a, "konet:floor")
        floor_b = watch(ch_b, "konet:floor")

        holder = ""
        try:
            holder = await ch_a.acquire_floor()
            check(6, "acquire floor", bool(holder), f"holder={holder!r}")
        except Exception as exc:
            _fail(6, "acquire floor", str(exc))

        ann_a = await floor_a.wait()
        ann_b = await floor_b.wait()
        check(
            7,
            "floor announced to both",
            isinstance(ann_a, dict) and isinstance(ann_b, dict)
            and ann_a.get("holder") == holder and ann_b.get("holder") == holder,
            f"A={ann_a} B={ann_b}",
        )

        # 8 — second holder refused, and told who has it
        try:
            await ch_b.acquire_floor()
            _fail(8, "second holder refused", "the second acquire succeeded")
        except Exception as exc:
            check(8, "second holder refused", "floor_held" in str(exc) or "détenue" in str(exc), str(exc))

        # 9/10 — binary reaches B, and must not echo to A
        payload = bytes([1, 2, 3, 250])
        bin_b = watch_binary(ch_b, "audio")
        bin_a = watch_binary(ch_a, "audio")

        await ch_a.send_binary("audio", payload)

        got_bin = await bin_b.wait()
        check(9, "binary frame round-trips", got_bin == payload, repr(got_bin))

        echoed = await bin_a.wait(timeout=0.6)
        check(10, "binary does not echo to sender", echoed is None, "sender received its own audio")

        # 11 — a client without the floor is refused; the channel survives it
        await ch_b.send_binary("audio", payload)
        await asyncio.sleep(0.3)

        survive = watch(ch_b, "conf:after-refusal")
        await ch_a.send("conf:after-refusal", {"ok": True})
        check(
            11,
            "channel survives a refused binary frame",
            await survive.wait() is not None,
            "no traffic after the refusal",
        )

        # 12 — release, then B can take it
        try:
            await ch_a.release_floor()
            new_holder = await ch_b.acquire_floor()
            check(12, "floor is transferable", bool(new_holder), f"holder={new_holder!r}")
            await ch_b.release_floor()
        except Exception as exc:
            _fail(12, "floor is transferable", str(exc))

        # 15 — a second socket of the *same* user shares the floor rather than
        # being refused. This is what made step 8 pass spuriously when both
        # clients used one token.
        same = KonetClient(URL, token=TOKEN, max_reconnect_tries=3)
        await same.connect()
        try:
            ch_same = same.channel(ROOM)
            await ch_same.subscribe()
            held = await ch_a.acquire_floor()
            also_held = await ch_same.acquire_floor()
            check(15, "the floor is per user, not per socket", held == also_held,
                  f"A={held!r} other socket={also_held!r}")
            await ch_a.release_floor()
        except Exception as exc:
            _fail(15, "the floor is per user, not per socket", str(exc))
        finally:
            await same.disconnect()

        # 13 — a late joiner receives the replay buffer
        c = KonetClient(URL, token=TOKEN, max_reconnect_tries=3)
        await c.connect()
        try:
            ch_c = c.channel(ROOM)
            history = watch(ch_c, "konet:history")
            await ch_c.subscribe()
            payload_h = await history.wait(timeout=4.0)
            check(13, "konet:history replay", history_shape_ok(payload_h), str(payload_h)[:200])
        finally:
            await c.disconnect()

        # 14 — still usable at the end of all that
        final = watch(ch_b, "conf:final")
        await ch_a.send("conf:final", {"done": True})
        check(14, "channel survives the whole scenario", await final.wait() is not None, "no final message")

    finally:
        await a.disconnect()
        await b.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
    if failures == 0:
        print("OK python")
        sys.exit(0)
    print(f"FAILED python ({failures})")
    sys.exit(1)
