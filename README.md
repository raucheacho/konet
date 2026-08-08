# Konet

> Self-hosted realtime infrastructure engine. WebSocket channels, presence, and broadcast — without the cloud lock-in.

## What is Konet?

Konet is a lightweight, self-hosted alternative to managed realtime services. It runs a Phoenix-powered WebSocket server packaged as a single Docker container, managed through a Go CLI, and consumed via idiomatic SDKs.

- **Channels** — pub/sub over WebSockets with room scoping  
- **Presence** — track who is online, with metadata  
- **Broadcast** — low-latency ephemeral events, with optional in-memory history replay for late joiners  
- **Binary frames** — media-rate transport with floor control, for push-to-talk and half-duplex audio  
- **JWT Auth** — stateless HMAC tokens, with per-channel scoping via token claims  
- **Rate Limiting** — per-socket message and per-IP connection throttling  
- **Webhooks** — POST channel/member lifecycle events to your backend, optionally HMAC-signed  
- **Prometheus Metrics** — `/metrics` endpoint for connections, channels, and throughput  
- **Studio Dashboard** — LiveView admin UI for monitoring, keys, and broadcast  

## Quick Start

### Local development (CLI)

```bash
# Install the CLI
brew install raucheacho/tap/konet

# Initialize, generate keys, and start
konet init
konet keys generate
konet start

# Open the studio
konet studio
```

### Self-hosting (VPS, Coolify, Dokploy)

Point your platform at `docker-compose.yml`, or run the image directly:

```bash
docker run -d --name konet -p 4000:4000 \
  -e KONET_JWT_SECRET="$(openssl rand -hex 32)" \
  -e SECRET_KEY_BASE="$(openssl rand -hex 32)" \
  -e KONET_STUDIO_PASSWORD="pick-a-password" \
  ghcr.io/raucheacho/konet:latest
```

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   SDKs      │────▶│ Konet Server │◀────│  Konet CLI  │
│ Go/JS/Py    │     │  Phoenix/Ex  │     │   (Go)      │
└─────────────┘     └──────────────┘     └─────────────┘
                           │
                    ┌──────┴──────┐
                    │   Docker    │
                    └─────────────┘
```

## SDKs

| Language | Package | Status |
|----------|---------|--------|
| JavaScript | `@raucheacho/konet-js` | ✅ |
| React Native | `@raucheacho/konet-rn` | ✅ |
| Go | `github.com/raucheacho/konet/sdk/go` | ✅ |
| Python | `konet` | ✅ |

## Documentation

Published at **https://raucheacho.github.io/konet/**, built from [`./docs`](./docs)
— a Nextra site deployed to GitHub Pages on every push to `main`.

To run it locally:

```bash
cd docs
bun install
bun run dev        # http://localhost:3000
```

`bun run build` produces a static export in `docs/out/`. CI builds it on every
push, so a broken page fails the build rather than shipping.

The deploy sets `NEXT_PUBLIC_BASE_PATH` because a project site is served under
`/konet`. Locally it is unset, so the dev server stays at `/`.

## License

MIT — see [LICENSE](./LICENSE) for details.
