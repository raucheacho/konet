from __future__ import annotations

import asyncio
import json
import math
from typing import Any
from urllib.parse import urlencode

import websockets
from websockets.exceptions import ConnectionClosed, WebSocketException

from .channel import Channel


class KonetClient:
    """
    Async Konet client.

    Usage::

        async with KonetClient("ws://localhost:4000/socket", token="kt_anon_...") as client:
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
    ) -> None:
        self._url = url
        self._token = token
        self._heartbeat_interval = heartbeat_interval
        self._reconnect_delay = reconnect_delay
        self._max_reconnect_tries = max_reconnect_tries

        self._ws: websockets.ClientConnection | None = None
        self._channels: dict[str, Channel] = {}
        self._ref_counter = 0
        self._connected = False
        self._tasks: list[asyncio.Task] = []

    async def __aenter__(self) -> "KonetClient":
        await self.connect()
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.disconnect()

    async def connect(self) -> None:
        params = urlencode({"token": self._token, "vsn": "2.0.0"})
        ws_url = f"{self._url}?{params}"

        self._ws = await websockets.connect(ws_url)
        self._connected = True

        self._tasks = [
            asyncio.create_task(self._read_loop()),
            asyncio.create_task(self._heartbeat_loop()),
        ]

    async def disconnect(self) -> None:
        self._connected = False
        for task in self._tasks:
            task.cancel()
        if self._ws:
            await self._ws.close()
            self._ws = None

    def channel(self, topic: str) -> Channel:
        if topic not in self._channels:
            self._channels[topic] = Channel(topic, self._send, self._next_ref)
        return self._channels[topic]

    async def _send(self, frame: list) -> None:
        if self._ws is None:
            raise RuntimeError("Not connected")
        await self._ws.send(json.dumps(frame))

    def _next_ref(self) -> str:
        self._ref_counter += 1
        return str(self._ref_counter)

    async def _read_loop(self) -> None:
        reconnect_attempts = 0
        while self._connected:
            try:
                if self._ws is None:
                    await asyncio.sleep(0.1)
                    continue

                raw = await self._ws.recv()
                frame = json.loads(raw)

                if not isinstance(frame, list) or len(frame) != 5:
                    continue

                _join_ref, _ref, topic, event, _payload = frame

                if topic == "phoenix":
                    continue

                ch = self._channels.get(topic)
                if ch:
                    ch._receive(frame)

                reconnect_attempts = 0

            except ConnectionClosed:
                if not self._connected:
                    break
                if reconnect_attempts >= self._max_reconnect_tries:
                    break
                delay = min(self._reconnect_delay * (2 ** reconnect_attempts), 30.0)
                reconnect_attempts += 1
                await asyncio.sleep(delay)
                await self._reconnect()

            except asyncio.CancelledError:
                break

    async def _heartbeat_loop(self) -> None:
        while self._connected:
            try:
                await asyncio.sleep(self._heartbeat_interval)
                ref = self._next_ref()
                await self._send([None, ref, "phoenix", "heartbeat", {}])
            except asyncio.CancelledError:
                break
            except Exception:
                pass

    async def _reconnect(self) -> None:
        try:
            params = urlencode({"token": self._token, "vsn": "2.0.0"})
            self._ws = await websockets.connect(f"{self._url}?{params}")
        except Exception:
            self._ws = None
