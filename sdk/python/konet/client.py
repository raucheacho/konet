from __future__ import annotations

import asyncio
import json
import random
from dataclasses import dataclass
from typing import Any, Callable, Literal
from urllib.parse import urlencode

import websockets
from websockets.exceptions import ConnectionClosed

from .binary import BROADCAST, PUSH, decode_server_frame, encode_push
from .channel import BinaryMode, Channel


#: What the connection is doing, as reported to :meth:`KonetClient.on_status`.
StatusState = Literal["connecting", "connected", "reconnecting", "disconnected", "failed"]

#: Ceiling on one reconnect delay, in seconds.
MAX_RECONNECT_DELAY = 30.0


@dataclass(frozen=True)
class ConnectionStatus:
    """A change of connection status.

    ``connecting``: a socket is being opened. ``connected``: it is open.
    ``reconnecting``: it was lost, and attempt ``attempt`` starts in ``delay``
    seconds. ``disconnected``: :meth:`KonetClient.disconnect` was called.
    ``failed``: ``max_reconnect_tries`` were used up and the client stopped.
    """

    state: StatusState
    attempt: int = 0
    delay: float = 0.0


def reconnect_delay(base: float, attempt: int, rand: Callable[[], float] = random.random) -> float:
    """Exponential backoff with "equal jitter": half the step fixed, half random.

    Without the random half, every client dropped by a server restart came back
    at the same 1 s, 2 s, 4 s — together, against a cold server and a per-IP
    connection budget. Never above the un-jittered step.
    """
    step = min(base * (2 ** attempt), MAX_RECONNECT_DELAY)
    return step / 2 + rand() * (step / 2)


class KonetClient:
    """
    Async Konet client.

    Usage::

        # The anon key printed by `konet keys generate` (a JWT).
        async with KonetClient("ws://localhost:4000/socket", token=os.environ["KONET_ANON_KEY"]) as client:
            channel = client.channel("room:lobby")
            await channel.subscribe()
            channel.on("message", lambda p: print(p))
            await channel.send("message", {"text": "Hello!"})
            await asyncio.sleep(60)
    """

    def __init__(
        self,
        url: str,
        *,
        token: str,
        heartbeat_interval: float = 30.0,
        reconnect_delay: float = 1.0,
        max_reconnect_tries: int = 10,
        heartbeat_timeout: float = 10.0,
    ) -> None:
        self._url = url
        self._token = token
        self._heartbeat_interval = heartbeat_interval
        self._reconnect_delay = reconnect_delay
        self._max_reconnect_tries = max_reconnect_tries
        # How long to wait for a heartbeat reply before declaring the socket
        # dead. Keep it below the server's socket timeout (45s).
        self._heartbeat_timeout = heartbeat_timeout

        self._ws: websockets.ClientConnection | None = None
        self._channels: dict[str, Channel] = {}
        self._ref_counter = 0
        self._connected = False
        self._tasks: list[asyncio.Task] = []
        self._rejoin_task: asyncio.Task | None = None
        self._pending_heartbeat_ref: str | None = None
        self._status_handlers: list[Callable[[ConnectionStatus], None]] = []

    def on_status(self, handler: Callable[[ConnectionStatus], None]) -> Callable[[], None]:
        """Call ``handler`` on every change of connection status.

        To show "reconnecting…", or to learn that the client gave up. Called
        synchronously from the client's own tasks: return quickly. Returns a
        callable that removes it.
        """
        self._status_handlers.append(handler)

        def off() -> None:
            try:
                self._status_handlers.remove(handler)
            except ValueError:
                pass  # already removed

        return off

    def _emit_status(self, status: ConnectionStatus) -> None:
        for handler in list(self._status_handlers):
            try:
                handler(status)
            except Exception:
                pass  # a failing UI callback must not take the connection with it

    async def __aenter__(self) -> "KonetClient":
        await self.connect()
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.disconnect()

    @property
    def connected(self) -> bool:
        """True while the socket is open and joins/sends can reach the server."""
        return self._connected and self._ws is not None

    def _websocket_url(self) -> str:
        # Phoenix mounts the actual websocket transport at "<socket path>/websocket",
        # not at the socket path itself (e.g. "/socket" -> "/socket/websocket").
        base = self._url.rstrip("/")
        params = urlencode({"token": self._token, "vsn": "2.0.0"})
        return f"{base}/websocket?{params}"

    async def connect(self) -> None:
        self._emit_status(ConnectionStatus("connecting"))
        self._ws = await websockets.connect(self._websocket_url())
        self._connected = True
        self._pending_heartbeat_ref = None
        self._emit_status(ConnectionStatus("connected"))

        self._tasks = [
            asyncio.create_task(self._read_loop()),
            asyncio.create_task(self._heartbeat_loop()),
        ]

    async def disconnect(self) -> None:
        was_active = self._connected or self._ws is not None or bool(self._tasks)
        self._connected = False
        if was_active:
            self._emit_status(ConnectionStatus("disconnected"))

        for task in self._tasks:
            task.cancel()
        self._tasks = []

        if self._rejoin_task is not None:
            self._rejoin_task.cancel()
            self._rejoin_task = None

        for channel in list(self._channels.values()):
            channel._socket_closed()

        if self._ws:
            await self._ws.close()
            self._ws = None

    def channel(self, topic: str, *, binary_mode: BinaryMode | None = None) -> Channel:
        """The channel for ``topic``, created on first use.

        ``binary_mode`` only applies then: a later call returns the same
        channel, and raises if it asks for a different mode rather than
        silently ignoring it. The mode belongs to the topic — a join asking for
        a different one from the members already there is refused with
        ``binary_mode_mismatch``.
        """
        existing = self._channels.get(topic)
        if existing is not None:
            current = existing.requested_binary_mode or "exclusive"
            if binary_mode is not None and binary_mode != current:
                raise ValueError(f"{topic} already exists in {current} mode")
            return existing

        channel = Channel(
            topic, self._send, self._send_binary, self._next_ref, binary_mode
        )
        self._channels[topic] = channel
        return channel

    async def _send(self, frame: list) -> None:
        if self._ws is None:
            raise RuntimeError("Not connected")
        await self._ws.send(json.dumps(frame))

    async def _send_binary(
        self, join_ref: str | None, ref: str, topic: str, event: str, data: bytes
    ) -> None:
        """Write a binary push.

        Never buffered while the socket is down, unlike text: replaying audio
        recorded seconds ago into a live channel would be worse than losing it
        — by the time it arrives, the moment has passed.
        """
        if self._ws is None:
            return
        await self._ws.send(encode_push(join_ref or "", ref, topic, event, data))

    def _next_ref(self) -> str:
        self._ref_counter += 1
        return str(self._ref_counter)

    async def _read_loop(self) -> None:
        while self._connected:
            ws = self._ws
            if ws is None:
                # Only reachable if a reconnect attempt left us without a
                # socket. Reconnect owns the backoff; never spin here.
                if not await self._reconnect():
                    return
                continue

            try:
                raw = await ws.recv()
            except ConnectionClosed:
                if not self._connected:
                    return
                if not await self._reconnect():
                    return
                continue
            except asyncio.CancelledError:
                raise

            self._dispatch(raw)

    def _dispatch(self, raw: str | bytes) -> None:
        # The opcode is what tells text from binary: websockets hands back
        # bytes for a binary frame and str for a text one.
        if isinstance(raw, (bytes, bytearray)):
            self._handle_binary(bytes(raw))
            return

        try:
            frame = json.loads(raw)
        except (ValueError, TypeError):
            return

        if not isinstance(frame, list) or len(frame) != 5:
            return

        _join_ref, ref, topic, _event, _payload = frame

        if topic == "phoenix":
            # The heartbeat reply is this client's only proof the server is
            # still there — it is the liveness signal, not noise to discard.
            if ref is not None and ref == self._pending_heartbeat_ref:
                self._pending_heartbeat_ref = None
            return

        ch = self._channels.get(topic)
        if ch:
            ch._receive(frame)

    def _handle_binary(self, raw: bytes) -> None:
        """Route a binary frame to its channel.

        A malformed frame is dropped rather than fatal: it must not take down
        the socket that carries every other channel.
        """
        frame = decode_server_frame(raw)
        if frame is None:
            return

        # A binary reply means the server refused the frame. Nothing waits on
        # one, since send_binary does not track refs.
        if frame.kind not in (BROADCAST, PUSH):
            return

        ch = self._channels.get(frame.topic)
        if ch:
            ch._receive_binary(frame.event, frame.data)

    async def _heartbeat_loop(self) -> None:
        # Probe once per heartbeat_interval, sending the probe heartbeat_timeout
        # before the end of the cycle so an unanswered one is caught within that
        # timeout rather than a full interval later.
        lead = max(self._heartbeat_interval - self._heartbeat_timeout, 0.0)

        while self._connected:
            try:
                await asyncio.sleep(lead)
                if not self._connected:
                    return

                ref = self._next_ref()
                self._pending_heartbeat_ref = ref
                try:
                    await self._send([None, ref, "phoenix", "heartbeat", {}])
                except Exception:
                    self._pending_heartbeat_ref = None
                    await asyncio.sleep(self._heartbeat_timeout)
                    continue

                await asyncio.sleep(self._heartbeat_timeout)

                # Still outstanding: whatever the local socket claims, nothing
                # is listening on the other end.
                if self._connected and self._pending_heartbeat_ref == ref:
                    await self._force_reconnect()

            except asyncio.CancelledError:
                return

    async def _force_reconnect(self) -> None:
        """Tear down a socket that is open locally but unreachable.

        Closing it makes the read loop's recv() raise, so reconnection stays in
        one place instead of racing this loop.
        """
        self._pending_heartbeat_ref = None
        ws = self._ws
        if ws is None:
            return
        try:
            await ws.close(code=4000, reason="heartbeat timeout")
        except Exception:
            pass  # already gone

    async def _reconnect(self) -> bool:
        """Re-open the socket with exponential backoff and restore the joins.

        Returns False once max_reconnect_tries is exhausted, which ends the read
        loop rather than leaving it awake with nothing to read.
        """
        # Every server-side join died with the socket. Marking the channels
        # makes send() fail loudly instead of writing into a dead topic, and
        # tells the rejoin which channels to restore.
        for channel in list(self._channels.values()):
            channel._socket_closed()

        self._ws = None
        self._pending_heartbeat_ref = None

        for attempt in range(self._max_reconnect_tries):
            if not self._connected:
                return False

            delay = reconnect_delay(self._reconnect_delay, attempt)
            self._emit_status(ConnectionStatus("reconnecting", attempt + 1, delay))
            await asyncio.sleep(delay)

            if not self._connected:
                return False

            self._emit_status(ConnectionStatus("connecting"))
            try:
                self._ws = await websockets.connect(self._websocket_url())
            except Exception:
                self._ws = None
                continue
            self._emit_status(ConnectionStatus("connected"))

            # The server knows nothing about the topics this client had joined
            # on the previous socket. Re-issue phx_join — but from a task, not
            # inline: a join awaits its reply, and that reply can only arrive
            # through the read loop that is calling us.
            if self._rejoin_task is not None:
                self._rejoin_task.cancel()
            self._rejoin_task = asyncio.create_task(self._rejoin_channels())
            return True

        # Used to end silently: an application had no way to know the client
        # had stopped trying, short of polling `connected` forever.
        self._connected = False
        self._emit_status(ConnectionStatus("failed"))
        return False

    async def _rejoin_channels(self) -> None:
        for channel in list(self._channels.values()):
            try:
                await channel._rejoin()
            except asyncio.CancelledError:
                raise
            except Exception:
                # One channel failing to re-join (an expired token, a room that
                # now refuses this client) must not stop the others.
                continue
