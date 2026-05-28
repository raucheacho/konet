from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from typing import Any, Callable, Awaitable

EventHandler = Callable[[Any], Awaitable[None] | None]


class Channel:
    def __init__(
        self,
        topic: str,
        send_fn: Callable,
        next_ref: Callable[[], str],
    ) -> None:
        self.topic = topic
        self._state: str = "idle"  # idle | joining | joined | errored
        self._send_fn = send_fn
        self._next_ref = next_ref
        self._join_ref: str | None = None
        self._handlers: dict[str, list[EventHandler]] = defaultdict(list)
        self._reply_futures: dict[str, asyncio.Future] = {}

    async def subscribe(self) -> None:
        if self._state in ("joined", "joining"):
            return

        self._state = "joining"
        ref = self._next_ref()
        self._join_ref = ref

        loop = asyncio.get_event_loop()
        fut: asyncio.Future = loop.create_future()
        self._reply_futures[ref] = fut

        await self._send_fn([ref, ref, self.topic, "phx_join", {}])

        reply = await asyncio.wait_for(fut, timeout=10.0)
        if reply.get("status") == "ok":
            self._state = "joined"
        else:
            self._state = "errored"
            raise RuntimeError(f"Failed to join {self.topic}: {reply.get('response')}")

    async def unsubscribe(self) -> None:
        if self._state != "joined":
            return
        ref = self._next_ref()
        self._state = "idle"
        await self._send_fn([self._join_ref, ref, self.topic, "phx_leave", {}])
        self._join_ref = None

    def on(self, event: str, handler: EventHandler) -> Callable[[], None]:
        """Register an event handler. Returns an unsubscribe callable."""
        self._handlers[event].append(handler)

        def off() -> None:
            self._handlers[event].remove(handler)

        return off

    async def send(self, event: str, payload: Any = None) -> None:
        if self._state != "joined":
            raise RuntimeError(f"Channel {self.topic} is not joined")

        ref = self._next_ref()
        await self._send_fn(
            [self._join_ref, ref, self.topic, "broadcast", {"event": event, "payload": payload or {}}]
        )

    def _receive(self, frame: list) -> None:
        """Called by the client when a message arrives for this topic."""
        _join_ref, ref, _topic, event, payload = frame

        if event == "phx_reply":
            fut = self._reply_futures.pop(ref, None)
            if fut and not fut.done():
                fut.set_result(payload if isinstance(payload, dict) else {})
            return

        for handler in list(self._handlers.get(event, [])):
            result = handler(payload)
            if asyncio.iscoroutine(result):
                asyncio.create_task(result)
