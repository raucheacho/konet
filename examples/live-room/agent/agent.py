"""
Konet Live Room — Python agent.

A non-human participant that joins the very same room as the browsers and
takes part over Broadcast: it glides a cursor around, throws reactions and
drops the occasional line of chat. It proves a Konet room is cross-runtime —
a JS front-end and a Python backend share one channel with no shared code.

Run:
    pip install -e ../../../sdk/python   # installs the `konet` SDK + websockets
    KONET_TOKEN=<anon_key> python agent.py

Options via env:
    KONET_URL    default ws://localhost:4000/socket
    KONET_TOKEN  required — your anon_key (`konet keys generate`)
    AGENT_NAME   default "Konet Bot"
"""

import asyncio
import math
import os
import random
import uuid

from konet import KonetClient

URL = os.environ.get("KONET_URL", "ws://localhost:4000/socket")
TOKEN = os.environ.get("KONET_TOKEN")
ROOM = "room:live-room"

AGENT = {
    "id": str(uuid.uuid4()),
    "name": os.environ.get("AGENT_NAME", "Konet Bot"),
    "color": "hsl(145 75% 62%)",
}

EMOJIS = ["🤖", "✨", "🎉", "🔥", "👋"]
LINES = [
    "hello from Python 👋",
    "same room, different language.",
    "no database, all in memory.",
    "broadcasting at low latency.",
    "presence says who's here.",
]


async def move_cursor(channel) -> None:
    """Glide along a Lissajous path so the motion looks organic."""
    t = 0.0
    while True:
        x = 0.5 + 0.35 * math.sin(t * 0.9)
        y = 0.5 + 0.28 * math.sin(t * 1.4 + 0.6)
        await channel.send(
            "cursor",
            {"id": AGENT["id"], "name": AGENT["name"], "color": AGENT["color"], "x": x, "y": y},
        )
        t += 0.08
        await asyncio.sleep(0.06)  # ~16 msgs/s


async def react(channel) -> None:
    while True:
        await asyncio.sleep(random.uniform(4, 9))
        await channel.send(
            "reaction",
            {"emoji": random.choice(EMOJIS), "x": random.uniform(0.2, 0.8), "y": random.uniform(0.6, 0.85)},
        )


async def chat(channel) -> None:
    while True:
        await asyncio.sleep(random.uniform(12, 22))
        await channel.send(
            "chat",
            {"id": AGENT["id"], "name": AGENT["name"], "color": AGENT["color"], "text": random.choice(LINES)},
        )


async def main() -> None:
    if not TOKEN:
        raise SystemExit("Set KONET_TOKEN to your anon_key (e.g. `konet keys generate`).")

    async with KonetClient(URL, token=TOKEN) as client:
        channel = client.channel(ROOM)
        await channel.subscribe()
        print(f"🤖 {AGENT['name']} joined {ROOM} on {URL}")

        # React to humans too: greet whoever says something.
        channel.on("chat", lambda p: _on_chat(p))

        await asyncio.gather(move_cursor(channel), react(channel), chat(channel))


def _on_chat(payload) -> None:
    if isinstance(payload, dict) and payload.get("id") != AGENT["id"]:
        print(f"  💬 {payload.get('name')}: {payload.get('text')}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 agent stopped")
