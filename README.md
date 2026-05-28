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

```bash
# Install the CLI
curl -sSL https://konet.io/install | sh

# Initialize and start
konet init
konet start

# Open the studio
konet studio
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
| JavaScript | `@konet-io/konet-js` | ✅ |
| Go | `github.com/konet-io/konet-sdk-go` | ✅ |
| Python | `konet-py` | ✅ |

## Documentation

Full docs live in [`./docs`](./docs). To run them locally:

```bash
cd docs
npm install
npm run dev
```

## License

MIT — see [LICENSE](./LICENSE) for details.
