# Konet · Live Room

A collaborative multiplayer room built on Konet — **live cursors, presence,
flying reactions, and chat**, all over WebSockets, with **no database**. A
Python agent joins the *same room* as the browsers to show a Konet channel is
cross-runtime.

What it exercises, end to end:

| You see | Konet feature |
|---|---|
| Other people's cursors moving live | **Broadcast** (low-latency ephemeral events) |
| "N online" counter | **Presence** |
| Emojis flying across the screen | **Broadcast** |
| Chat backlog when you join late | **History** replay (`konet:history`) |
| A 🤖 that moves, reacts and chats | Cross-runtime channel (JS + Python SDK) |
| The Studio link in the top bar | **Studio** dashboard |

## Prerequisites

- A running Konet server (`konet start`) — see the repo root README.
- Your **`anon_key`** — generate it with `konet keys generate`, or copy it from
  Studio → Keys. Both the web app and the agent connect with it.
- Node 18+ and Python 3.10+.

> **Tip — enable the chat backlog.** History replay is off by default. Start the
> server with `KONET_HISTORY_LIMIT=50` so late joiners receive recent chat.
> Everything else works without it.

## 1. Run the web app

```bash
cd web
npm install      # pulls the local SDK via file:../../../sdk/js
npm run dev
```

Open the printed URL (usually http://localhost:5173), paste your `anon_key`,
and enter the room. Open a second tab to see cursors and presence sync.

## 2. Run the Python agent (optional, but the fun part)

In another terminal:

```bash
cd agent
python -m venv .venv && source .venv/bin/activate
pip install -e ../../../sdk/python     # installs the `konet` SDK
KONET_TOKEN=<your anon_key> python agent.py
```

The 🤖 appears in every open browser, gliding around and chatting.

## How it works

- **Cursors & reactions** ride on `channel.send("cursor" | "reaction", …)`.
  Coordinates are normalised to `0..1` so every screen size lines up.
- **Presence metadata is fixed server-side** (`online_at/room/role`), so each
  client carries its own `name`/`color`/`id` inside broadcast payloads and
  ignores the echo of its own messages (Phoenix delivers a broadcast back to
  its sender).
- **Chat** is a broadcast too; the last N messages are replayed to late
  joiners via a single `konet:history` push when history is enabled.

## Files

```
web/            Vite front-end (vanilla JS + @raucheacho/konet-js)
  src/main.js   all the client logic
agent/agent.py  the Python participant (konet SDK)
```
