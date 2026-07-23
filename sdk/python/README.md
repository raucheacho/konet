# konet (Python SDK)

Async Python SDK for [Konet](https://github.com/raucheacho/konet), the
self-hosted realtime engine (channels, presence, broadcast).

## Install

```bash
pip install konet
```

## Usage

```python
import asyncio
from konet import KonetClient

async def main():
    async with KonetClient("ws://localhost:4000/socket", token="<your-token>") as client:
        channel = client.channel("room:lobby")
        await channel.subscribe()
        channel.on("message", lambda payload: print(payload))
        await channel.send("message", {"text": "Hello!"})
        await asyncio.sleep(60)

asyncio.run(main())
```

## License

MIT
