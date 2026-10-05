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

## Options

```python
client = KonetClient(
    url,
    token=...,                # keyword-only
    heartbeat_interval=30.0,
    reconnect_delay=1.0,      # backoff base, jittered, capped at 30 s
    max_reconnect_tries=10,
    heartbeat_timeout=10.0,
)

# connecting | connected | reconnecting (status.attempt, status.delay)
# | disconnected | failed (reconnect attempts used up)
off = client.on_status(lambda status: print(status.state))
```

The client reconnects on its own and re-joins every channel you subscribed to.

## Binary frames

For audio or anything else at a media rate. Each topic runs one of two modes,
chosen when the channel is created; every member must ask for the same one.

```python
# Push-to-talk — "exclusive", the default: one sender at a time, by floor.
ptt = client.channel("room:team-42:ptt")
await ptt.subscribe()
await ptt.acquire_floor()           # raises, naming the holder, if taken
await ptt.send_binary("a", frame)   # frame: bytes
await ptt.release_floor()
ptt.on_binary("a", lambda data: ...)

# A call — "multiplex": everyone sends at once, no floor.
call = client.channel("room:call-7", binary_mode="multiplex")
await call.subscribe()
call.on_binary_from("a", lambda data, sender: ...)
await call.send_binary("a", frame)

# A refused frame (no floor, rate limited), at most once per reason per second.
call.on("binary_error", lambda e: print(e["reason"]))
```

`call.binary_mode` is the mode the server confirmed. A join asking for the other
mode than the topic's members fails with `binary_mode_mismatch`; a multiplex
topic beyond the server's member ceiling, with `topic_full`.
Details: [binary frames](https://raucheacho.github.io/konet/reference/binary).

## License

MIT
