# Konet

> Self-hosted realtime infrastructure engine. WebSocket channels, presence, and broadcast — without the cloud lock-in.

## What is Konet?

Konet is a lightweight, self-hosted alternative to managed realtime services. It runs a Phoenix-powered WebSocket server packaged as a single Docker container, managed through a Go CLI, and consumed via idiomatic SDKs.

- **Channels** — pub/sub over WebSockets with room scoping  
- **Presence** — track who is online, with metadata  
- **JWT Auth** — stateless token validation built-in  
- **Rate Limiting** — per-socket message throttling  
- **Studio Dashboard** — LiveView admin UI for monitoring, keys, and broadcast  

## Quick Start

### Local development (CLI)

```bash
# Install the CLI
brew install raucheacho/tap/konet

# Initialize and start
konet init
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
| Go | `github.com/raucheacho/konet/sdk/go` | ✅ |
| Python | `konet` | ✅ |

## Documentation

Full docs live in [`./docs`](./docs). To run them locally:

```bash
cd docs
npm install
npm run dev
```

## License

MIT — see [LICENSE](./LICENSE) for details.
