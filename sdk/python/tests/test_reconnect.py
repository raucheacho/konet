"""Reconnexion et re-join.

The server keeps no memory of the topics a client had joined on a previous
socket, so a reconnect that does not re-issue phx_join leaves the client
*looking* connected while every send lands on a topic the socket never joined —
and Konet only replies to broadcasts it refuses, so nothing ever errors.

These tests drive a fake socket rather than a real server: what is being pinned
is the client's own state machine, not the protocol (tests/test_binary.py covers
that).
"""

from __future__ import annotations

import asyncio
import json

import pytest
from websockets.exceptions import ConnectionClosed

from konet.client import KonetClient

_CLOSED = object()


class FakeSocket:
    """Enough of a websockets connection for KonetClient, plus a way to drop it."""

    def __init__(self) -> None:
        self.sent: list[list] = []
        self.sent_binary: list[bytes] = []
        self.closed = False
        self._incoming: asyncio.Queue = asyncio.Queue()

    async def send(self, data) -> None:
        if self.closed:
            raise ConnectionClosed(None, None)
        if isinstance(data, (bytes, bytearray)):
            self.sent_binary.append(bytes(data))
        else:
            self.sent.append(json.loads(data))

    async def recv(self):
        item = await self._incoming.get()
        if item is _CLOSED:
            raise ConnectionClosed(None, None)
        return item

    async def close(self, code=None, reason=None) -> None:
        self.drop()

    def drop(self) -> None:
        """Simulate the network going away."""
        if not self.closed:
            self.closed = True
            self._incoming.put_nowait(_CLOSED)

    def deliver(self, frame: list) -> None:
        self._incoming.put_nowait(json.dumps(frame))

    def reply_ok(self, ref: str, topic: str, response: dict | None = None) -> None:
        self.deliver([None, ref, topic, "phx_reply",
                      {"status": "ok", "response": response or {}}])

    def joins(self) -> list[list]:
        return [f for f in self.sent if f[3] == "phx_join"]


class FakeTransport:
    """Stands in for websockets.connect, handing out one FakeSocket per call."""

    def __init__(self, fail_times: int = 0) -> None:
        self.sockets: list[FakeSocket] = []
        self.fail_times = fail_times
        self.attempts = 0

    async def __call__(self, _url: str) -> FakeSocket:
        self.attempts += 1
        if self.fail_times > 0:
            self.fail_times -= 1
            raise OSError("connection refused")
        socket = FakeSocket()
        self.sockets.append(socket)
        return socket

    @property
    def current(self) -> FakeSocket:
        return self.sockets[-1]


def run(coro):
    return asyncio.run(coro)


async def _client(monkeypatch, transport: FakeTransport, **kwargs) -> KonetClient:
    import konet.client as client_module

    monkeypatch.setattr(client_module.websockets, "connect", transport)
    kwargs.setdefault("heartbeat_interval", 3600.0)  # out of the way by default
    client = KonetClient(
        "ws://test/socket",
        token="tok",
        reconnect_delay=0.001,
        **kwargs,
    )
    await client.connect()
    return client


async def _join(client: KonetClient, transport: FakeTransport, topic="room:lobby"):
    """Subscribe and answer the join the client sends."""
    channel = client.channel(topic)
    task = asyncio.create_task(channel.subscribe())
    await asyncio.sleep(0)  # let the join go out
    join = transport.current.joins()[-1]
    transport.current.reply_ok(join[1], topic)
    await task
    return channel


# ── Re-join ────────────────────────────────────────────────────────────────


def test_rejoins_after_a_dropped_connection(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)
        channel = await _join(client, transport)
        assert channel._state == "joined"

        first = transport.current
        first.drop()

        # The reconnect opens a new socket and re-issues phx_join on it.
        for _ in range(200):
            await asyncio.sleep(0.005)
            if len(transport.sockets) > 1 and transport.current.joins():
                break

        assert len(transport.sockets) == 2, "expected a new socket"
        rejoin = transport.current.joins()[-1]
        assert rejoin[2] == "room:lobby"

        transport.current.reply_ok(rejoin[1], "room:lobby")
        await asyncio.sleep(0.05)
        assert channel._state == "joined"

        await client.disconnect()

    run(scenario())


def test_does_not_rejoin_a_channel_that_was_left(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)
        kept = await _join(client, transport, "room:lobby")
        left = await _join(client, transport, "room:other")
        await left.unsubscribe()

        transport.current.drop()

        for _ in range(200):
            await asyncio.sleep(0.005)
            if len(transport.sockets) > 1 and transport.current.joins():
                break

        topics = [f[2] for f in transport.current.joins()]
        assert "room:lobby" in topics
        assert "room:other" not in topics
        assert kept._wants_join is True
        assert left._wants_join is False

        await client.disconnect()

    run(scenario())


def test_send_fails_loudly_while_disconnected(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)
        channel = await _join(client, transport)

        transport.current.drop()
        await asyncio.sleep(0)

        # Before the fix this silently wrote into a topic the socket had never
        # joined, and the server never replies to an accepted broadcast — so
        # the caller had no way at all to notice.
        with pytest.raises(RuntimeError):
            await channel.send("message", {"text": "lost"})

        await client.disconnect()

    run(scenario())


def test_pending_replies_fail_instead_of_hanging(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)
        channel = await _join(client, transport)

        floor = asyncio.create_task(channel.acquire_floor())
        await asyncio.sleep(0)
        transport.current.drop()

        # Would otherwise sit on its 10s timeout.
        with pytest.raises((ConnectionError, RuntimeError)):
            await asyncio.wait_for(floor, timeout=1.0)

        await client.disconnect()

    run(scenario())


# ── Giving up ──────────────────────────────────────────────────────────────


def test_gives_up_after_max_tries_instead_of_spinning(monkeypatch):
    async def scenario():
        # Every reconnect attempt fails: the read loop must exit rather than
        # busy-loop at 10Hz on a None socket.
        transport = FakeTransport()
        client = await _client(monkeypatch, transport, max_reconnect_tries=3)
        await _join(client, transport)

        transport.fail_times = 99
        transport.current.drop()

        read_loop = client._tasks[0]
        for _ in range(400):
            await asyncio.sleep(0.005)
            if read_loop.done():
                break

        assert read_loop.done(), "read loop should have exited, not spun on a None socket"
        assert client.connected is False
        assert transport.attempts == 1 + 3, "one initial connect plus max_reconnect_tries"

        await client.disconnect()

    run(scenario())


# ── Liveness ───────────────────────────────────────────────────────────────


def test_unanswered_heartbeat_forces_a_reconnect(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(
            monkeypatch, transport, heartbeat_interval=0.05, heartbeat_timeout=0.02
        )
        await _join(client, transport)

        # The socket stays "open" locally and simply never answers — the case a
        # dropped connection never signals.
        for _ in range(200):
            await asyncio.sleep(0.005)
            if len(transport.sockets) > 1:
                break

        assert len(transport.sockets) > 1, "a dead-but-open socket should be replaced"

        await client.disconnect()

    run(scenario())


def test_answered_heartbeat_keeps_the_socket(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(
            monkeypatch, transport, heartbeat_interval=0.05, heartbeat_timeout=0.02
        )
        await _join(client, transport)

        socket = transport.current
        answered = 0

        # Answer every probe for several heartbeat cycles.
        for _ in range(80):
            await asyncio.sleep(0.005)
            ref = client._pending_heartbeat_ref
            if ref is not None:
                socket.deliver([None, ref, "phoenix", "phx_reply",
                                {"status": "ok", "response": {}}])
                answered += 1
            await asyncio.sleep(0)

        assert answered >= 2, "the heartbeat should have probed more than once"
        assert len(transport.sockets) == 1, "an answered probe must not reconnect"

        await client.disconnect()

    run(scenario())


# ── Binary mode ────────────────────────────────────────────────────────────


def test_default_join_asks_for_no_mode_and_reads_exclusive(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)
        channel = await _join(client, transport)

        # Unchanged on the wire for every existing push-to-talk client.
        assert transport.current.joins()[-1][4] == {}
        # The reply carries no mode, as from a server older than it.
        assert channel.binary_mode == "exclusive"

        await client.disconnect()

    run(scenario())


def test_multiplex_is_asked_on_every_join(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        client = await _client(monkeypatch, transport)

        channel = client.channel("room:call", binary_mode="multiplex")
        task = asyncio.create_task(channel.subscribe())
        await asyncio.sleep(0)
        join = transport.current.joins()[-1]
        assert join[4] == {"binary_mode": "multiplex"}
        transport.current.reply_ok(join[1], "room:call", {"binary_mode": "multiplex"})
        await task
        assert channel.binary_mode == "multiplex"

        # The server forgets a topic's mode once it empties, so a rejoin that
        # dropped the parameter would come back exclusive — or be refused.
        transport.current.drop()
        for _ in range(200):
            await asyncio.sleep(0.005)
            if len(transport.sockets) > 1 and transport.current.joins():
                break

        assert channel.binary_mode is None
        assert transport.current.joins()[-1][4] == {"binary_mode": "multiplex"}

        await client.disconnect()

    run(scenario())


def test_channel_refuses_a_different_mode_for_an_existing_topic():
    client = KonetClient("ws://test/socket", token="tok")
    channel = client.channel("room:call", binary_mode="multiplex")

    assert client.channel("room:call") is channel
    assert client.channel("room:call", binary_mode="multiplex") is channel
    with pytest.raises(ValueError, match="multiplex"):
        client.channel("room:call", binary_mode="exclusive")
    with pytest.raises(ValueError, match="unknown"):
        client.channel("room:other", binary_mode="duplex")


# ── Backoff and status ─────────────────────────────────────────────────────


def test_reconnect_delay_jitters_half_of_each_step():
    from konet.client import reconnect_delay

    assert reconnect_delay(1.0, 0, lambda: 0.0) == 0.5
    assert reconnect_delay(1.0, 0, lambda: 1.0) == 1.0
    assert reconnect_delay(1.0, 2, lambda: 0.5) == 3.0
    assert reconnect_delay(1.0, 20, lambda: 1.0) == 30.0  # ceiling
    assert reconnect_delay(1.0, 20, lambda: 0.0) == 15.0
    # Clients dropped at the same moment no longer come back together.
    assert len({reconnect_delay(1.0, 3) for _ in range(20)}) > 1


def test_status_reports_each_step_including_giving_up(monkeypatch):
    async def scenario():
        transport = FakeTransport()
        seen = []

        import konet.client as client_module

        monkeypatch.setattr(client_module.websockets, "connect", transport)
        client = KonetClient("ws://test/socket", token="tok", reconnect_delay=0.001,
                             max_reconnect_tries=2, heartbeat_interval=3600.0)
        off = client.on_status(seen.append)
        # A failing handler must not break anything.
        client.on_status(lambda _s: 1 / 0)

        await client.connect()
        transport.fail_times = 99
        transport.current.drop()

        for _ in range(400):
            await asyncio.sleep(0.005)
            if seen and seen[-1].state == "failed":
                break

        assert [s.state for s in seen] == [
            "connecting", "connected",
            "reconnecting", "connecting",
            "reconnecting", "connecting",
            "failed",
        ]
        assert seen[2].attempt == 1 and 0.0005 <= seen[2].delay <= 0.001

        await client.disconnect()
        assert seen[-1].state == "disconnected"

        off()
        count = len(seen)
        await client.disconnect()
        assert len(seen) == count

    run(scenario())
