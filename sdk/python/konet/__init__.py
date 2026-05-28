"""
konet-py — Python SDK for Konet realtime infrastructure.

Quick start::

    import asyncio
    from konet import KonetClient

    async def main():
        async with KonetClient("ws://localhost:4000/socket", token="kt_anon_...") as client:
            channel = client.channel("room:lobby")
            await channel.subscribe()

            channel.on("message", lambda p: print("received:", p))
            await channel.send("message", {"text": "Hello from Python!"})
            await asyncio.sleep(60)

    asyncio.run(main())
"""

from .client import KonetClient
from .channel import Channel

__all__ = ["KonetClient", "Channel"]
__version__ = "0.1.0"
