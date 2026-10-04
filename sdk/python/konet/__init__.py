"""
konet — Python SDK for Konet realtime infrastructure.

Quick start::

    import asyncio
    import os
    from konet import KonetClient

    async def main():
        # The anon key printed by `konet keys generate` (a JWT).
        async with KonetClient("ws://localhost:4000/socket", token=os.environ["KONET_ANON_KEY"]) as client:
            channel = client.channel("room:lobby")
            await channel.subscribe()

            channel.on("message", lambda p: print("received:", p))
            await channel.send("message", {"text": "Hello from Python!"})
            await asyncio.sleep(60)

    asyncio.run(main())
"""

from .client import ConnectionStatus, KonetClient
from .channel import BinaryMode, Channel

__all__ = ["KonetClient", "Channel", "BinaryMode", "ConnectionStatus"]
__version__ = "0.1.0"
