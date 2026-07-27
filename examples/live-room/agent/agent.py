"""
Konet Live Room — Python agent (stress-test mode).

Spawns N bot agents that all join the same room. Each bot moves a cursor,
throws reactions at a configurable rate, and chats occasionally.
Use this to push the Konet server to its limits.

Run:
    KONET_TOKEN=<anon_key> uv run python agent.py

Options via env:
    KONET_URL        default ws://localhost:4000/socket
    KONET_TOKEN      required — your anon_key
    AGENT_COUNT      number of bots to spawn       (default 1000)
    REACTION_SPEED   seconds between reactions      (default 0.3)
    CURSOR_SPEED     seconds between cursor updates (default 0.1)
    CHAT_SPEED       seconds between chat messages  (default 5)
    STAGGER          seconds between bot launches   (default 0.02)
"""

import asyncio
import math
import os
import random
import uuid

from konet import KonetClient

# ─── Config ───────────────────────────────────────────────────────────
URL = os.environ.get("KONET_URL", "ws://localhost:4000/socket")
TOKEN = os.environ.get("KONET_TOKEN")
ROOM = "room:live-room"

AGENT_COUNT = int(os.environ.get("AGENT_COUNT", "50"))
REACTION_SPEED = float(os.environ.get("REACTION_SPEED", "0.3"))
CURSOR_SPEED = float(os.environ.get("CURSOR_SPEED", "0.1"))
CHAT_SPEED = float(os.environ.get("CHAT_SPEED", "5"))
STAGGER = float(os.environ.get("STAGGER", "0.02"))

# ─── Shared data ──────────────────────────────────────────────────────
EMOJIS = ["🤖", "✨", "🎉", "🔥", "👋", "💥", "⚡", "🚀", "🌈", "💀"]
LINES = [
    "hello from Python 👋",
    "same room, different language.",
    "no database, all in memory.",
    "broadcasting at low latency.",
    "presence says who's here.",
    "stress test in progress 🔥",
    "how many can you handle?",
]
COLORS = [
    "hsl(145 75% 62%)",
    "hsl(200 80% 55%)",
    "hsl(280 70% 60%)",
    "hsl(340 75% 58%)",
    "hsl(50 90% 55%)",
    "hsl(170 65% 50%)",
    "hsl(20 85% 60%)",
    "hsl(95 70% 50%)",
    "hsl(230 75% 65%)",
    "hsl(310 65% 55%)",
]

# ─── Stats ────────────────────────────────────────────────────────────
stats = {"sent": 0, "connected": 0, "errors": 0}


def make_agent(index: int) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "name": f"Bot-{index:04d}",
        "color": COLORS[index % len(COLORS)],
    }


# ─── Per-bot loops ────────────────────────────────────────────────────
async def move_cursor(channel, agent: dict) -> None:
    t = random.uniform(0, 100)  # offset so bots don't overlap
    while True:
        x = 0.5 + 0.35 * math.sin(t * 0.9)
        y = 0.5 + 0.28 * math.sin(t * 1.4 + 0.6)
        await channel.send(
            "cursor",
            {
                "id": agent["id"],
                "name": agent["name"],
                "color": agent["color"],
                "x": x,
                "y": y,
            },
        )
        stats["sent"] += 1
        t += 0.08
        await asyncio.sleep(CURSOR_SPEED)


async def react(channel, agent: dict) -> None:
    while True:
        jitter = REACTION_SPEED * random.uniform(0.5, 1.5)
        await asyncio.sleep(jitter)
        await channel.send(
            "reaction",
            {
                "emoji": random.choice(EMOJIS),
                "x": random.uniform(0.1, 0.9),
                "y": random.uniform(0.3, 0.9),
            },
        )
        stats["sent"] += 1


async def chat(channel, agent: dict) -> None:
    while True:
        jitter = CHAT_SPEED * random.uniform(0.8, 1.5)
        await asyncio.sleep(jitter)
        await channel.send(
            "chat",
            {
                "id": agent["id"],
                "name": agent["name"],
                "color": agent["color"],
                "text": random.choice(LINES),
            },
        )
        stats["sent"] += 1


# ─── Single bot lifecycle ─────────────────────────────────────────────
async def run_bot(index: int) -> None:
    agent = make_agent(index)
    try:
        async with KonetClient(URL, token=TOKEN) as client:
            channel = client.channel(ROOM)
            await channel.subscribe()
            stats["connected"] += 1
            await asyncio.gather(
                move_cursor(channel, agent),
                react(channel, agent),
                chat(channel, agent),
            )
    except Exception as exc:  # noqa: BLE001
        stats["errors"] += 1
        print(f"  ❌ {agent['name']} failed: {exc}")


# ─── Live stats printer ───────────────────────────────────────────────
async def print_stats() -> None:
    prev = 0
    while True:
        await asyncio.sleep(2)
        current = stats["sent"]
        rate = (current - prev) / 2
        prev = current
        print(
            f"bots={stats['connected']}/{AGENT_COUNT}  "
            f"sent={current:,}  "
            f"rate={rate:,.0f} msg/s  "
            f"errors={stats['errors']}"
        )


# ─── Main ─────────────────────────────────────────────────────────────
async def main() -> None:
    if not TOKEN:
        raise SystemExit(
            "Set KONET_TOKEN to your anon_key (e.g. `konet keys generate`)."
        )

    print(f"🚀 Launching {AGENT_COUNT} bots → {URL}")
    print(
        f"   reaction_speed={REACTION_SPEED}s  cursor_speed={CURSOR_SPEED}s  chat_speed={CHAT_SPEED}s"
    )
    print(f"   stagger={STAGGER}s  (total ramp-up ≈ {AGENT_COUNT * STAGGER:.1f}s)")
    print()

    tasks = [asyncio.create_task(print_stats())]

    for i in range(AGENT_COUNT):
        tasks.append(asyncio.create_task(run_bot(i)))
        if STAGGER > 0:
            await asyncio.sleep(STAGGER)

    print(f"✅ All {AGENT_COUNT} bots launched — watching stats (Ctrl+C to stop)")
    print()

    await asyncio.gather(*tasks)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(
            f"\n👋 stopped — {stats['sent']:,} total messages sent, {stats['errors']} errors"
        )
