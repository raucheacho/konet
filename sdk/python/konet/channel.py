from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any, Callable, Awaitable

EventHandler = Callable[[Any], Awaitable[None] | None]
#: Handles an incoming binary frame.
BinaryHandler = Callable[[bytes], Awaitable[None] | None]


class Channel:
    def __init__(
        self,
        topic: str,
        send_fn: Callable,
        send_binary_fn: Callable,
        next_ref: Callable[[], str],
    ) -> None:
        self.topic = topic
        self._state: str = "idle"  # idle | joining | joined | errored
        self._send_fn = send_fn
        self._send_binary_fn = send_binary_fn
        self._next_ref = next_ref
        self._join_ref: str | None = None
        self._handlers: dict[str, list[EventHandler]] = defaultdict(list)
        # Kept apart from _handlers because a binary event delivers bytes, not
        # a decoded payload, and mixing them would force every handler to
        # check a type it already knows.
        self._binary_handlers: dict[str, list[BinaryHandler]] = defaultdict(list)
        self._reply_futures: dict[str, asyncio.Future] = {}
        # Whether the application wants this channel joined. Survives socket
        # drops, so a reconnect knows what to restore; cleared only by
        # unsubscribe(), so a channel the caller deliberately left is never
        # silently re-joined.
        self._wants_join = False

    async def subscribe(self) -> None:
        self._wants_join = True

        if self._state in ("joined", "joining"):
            return

        self._state = "joining"
        ref = self._next_ref()
        self._join_ref = ref

        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        self._reply_futures[ref] = fut

        try:
            await self._send_fn([ref, ref, self.topic, "phx_join", {}])
        except Exception:
            self._state = "errored"
            self._reply_futures.pop(ref, None)
            raise

        try:
            reply = await asyncio.wait_for(fut, timeout=10.0)
        except (asyncio.TimeoutError, ConnectionError):
            self._state = "errored"
            self._reply_futures.pop(ref, None)
            raise

        # A reply from a join that a reconnect already superseded.
        if self._join_ref != ref:
            return

        if reply.get("status") == "ok":
            self._state = "joined"
        else:
            self._state = "errored"
            # _wants_join stays set: a rejection is often a stale or expired
            # token, and the next reconnect should try again with whatever
            # token the client holds by then.
            raise RuntimeError(f"Failed to join {self.topic}: {reply.get('response')}")

    async def unsubscribe(self) -> None:
        self._wants_join = False

        if self._state != "joined":
            self._state = "idle"
            self._join_ref = None
            return

        ref = self._next_ref()
        self._state = "idle"
        join_ref = self._join_ref
        self._join_ref = None
        await self._send_fn([join_ref, ref, self.topic, "phx_leave", {}])

    def on(self, event: str, handler: EventHandler) -> Callable[[], None]:
        """Register an event handler. Returns an unsubscribe callable."""
        self._handlers[event].append(handler)

        def off() -> None:
            try:
                self._handlers[event].remove(handler)
            except ValueError:
                pass  # already removed

        return off

    async def send(self, event: str, payload: Any = None) -> None:
        if self._state != "joined":
            raise RuntimeError(f"Channel {self.topic} is not joined")

        ref = self._next_ref()
        await self._send_fn(
            [self._join_ref, ref, self.topic, "broadcast", {"event": event, "payload": payload or {}}]
        )

    async def send_binary(self, event: str, data: bytes) -> None:
        """Send a binary frame — audio, or anything else at a media rate.

        Three things differ from :meth:`send`, and all follow from the rate:
        Phoenix frames it natively instead of base64 inside JSON, the server
        never acknowledges it, and it is refused unless this client holds the
        channel's floor. Take the floor with :meth:`acquire_floor` first.
        """
        if self._state != "joined":
            raise RuntimeError(f"Channel {self.topic} is not joined")

        # Not tracked like send(): at fifty frames a second, a future per frame
        # would cost more than the frames do.
        await self._send_binary_fn(self._join_ref, self._next_ref(), self.topic, event, data)

    def on_binary(self, event: str, handler: BinaryHandler) -> Callable[[], None]:
        """Register a handler for binary frames. Returns an unsubscribe callable."""
        self._binary_handlers[event].append(handler)

        def off() -> None:
            try:
                self._binary_handlers[event].remove(handler)
            except ValueError:
                pass  # already removed

        return off

    async def acquire_floor(self) -> str:
        """Claim the right to send on this channel.

        At most one member holds it at a time, which is how half-duplex media —
        push-to-talk — is arbitrated. Returns the holder, which is this client
        on success; raises naming whoever already holds it otherwise.
        """
        response = await self._request("konet:floor_acquire")
        return response.get("holder", "")

    async def release_floor(self) -> None:
        """Give the floor back. Only the holder may."""
        await self._request("konet:floor_release")

    async def _request(self, event: str) -> dict:
        """A push that expects a reply, unlike the fire-and-forget send()."""
        if self._state != "joined":
            raise RuntimeError(f"Channel {self.topic} is not joined")

        ref = self._next_ref()
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._reply_futures[ref] = fut

        await self._send_fn([self._join_ref, ref, self.topic, event, {}])

        try:
            reply = await asyncio.wait_for(fut, timeout=10.0)
        except asyncio.TimeoutError:
            self._reply_futures.pop(ref, None)
            raise RuntimeError(f"{event} sans réponse") from None
        except ConnectionError:
            self._reply_futures.pop(ref, None)
            raise

        if reply.get("status") != "ok":
            refusal = reply.get("response") or {}
            holder = refusal.get("holder")
            reason = refusal.get("reason", "refusé")
            if holder:
                raise RuntimeError(f"{reason} (détenue par {holder})")
            raise RuntimeError(f"{event} refusé ({reason})")

        return reply.get("response") or {}

    # ── Reconnection hooks, called by KonetClient ───────────────────────────

    def _socket_closed(self) -> None:
        """The socket went away, taking the server-side join with it.

        Marks the channel as no longer joined so send() fails loudly instead of
        writing into a dead topic, and tells the next _rejoin() what to restore.
        """
        if self._state in ("joined", "joining"):
            self._state = "idle"
        self._join_ref = None

        # Anything waiting on a reply will never get one: the socket that
        # carried the request is gone. Fail them rather than let them sit until
        # their 10s timeout.
        pending, self._reply_futures = self._reply_futures, {}
        for fut in pending.values():
            if not fut.done():
                fut.set_exception(
                    ConnectionError(f"socket closed before {self.topic} replied")
                )

    async def _rejoin(self) -> None:
        """The socket is (re)open — restore the join the server lost."""
        if not self._wants_join:
            return
        if self._state in ("joined", "joining"):
            return
        await self.subscribe()

    # ── Inbound dispatch ────────────────────────────────────────────────────

    def _receive_binary(self, event: str, data: bytes) -> None:
        """Called by the client when a binary frame arrives for this topic."""
        for handler in list(self._binary_handlers.get(event, [])):
            result = handler(data)
            if asyncio.iscoroutine(result):
                asyncio.create_task(result)

    def _receive(self, frame: list) -> None:
        """Called by the client when a message arrives for this topic."""
        _join_ref, ref, _topic, event, payload = frame

        if event == "phx_reply":
            fut = self._reply_futures.pop(ref, None)
            if fut and not fut.done():
                fut.set_result(payload if isinstance(payload, dict) else {})
            return

        if event == "phx_error":
            self._state = "errored"
        elif event == "phx_close":
            self._state = "idle"

        for handler in list(self._handlers.get(event, [])):
            result = handler(payload)
            if asyncio.iscoroutine(result):
                asyncio.create_task(result)
