# 01 — Getting started (contributor setup)

## Required toolchain

| Tool | Version | Where it is pinned |
|---|---|---|
| Elixir | `~> 1.16` (CI and image use **1.16.3**) | `konet-server/mix.exs`, `.github/workflows/ci.yml`, `konet-server/Dockerfile` (`ARG ELIXIR_VERSION`) |
| Erlang/OTP | **26.2** in CI, **26.2.5** in the image | `.github/workflows/ci.yml`, `konet-server/Dockerfile` (`ARG OTP_VERSION`) |
| Go (CLI) | **1.25.0** | `konet-cli/go.mod` |
| Go (SDK) | **1.23** | `sdk/go/go.mod` |
| Node | **20** | `.github/workflows/ci.yml`, and the image installs `setup_20.x` for esbuild |
| Python | **3.10+** required, **3.12** in CI, `3.11` for the demo agent | `sdk/python/pyproject.toml`, `examples/live-room/agent/.python-version` |
| Bun | latest | used only for `docs/` (the public site) |
| Docker | any recent version | needed by `konet start` and by docker-compose |

CI uses `go-version-file:` for both Go modules, so bumping `go.mod` bumps CI
too. Elixir and OTP are duplicated between `ci.yml` and the `Dockerfile` and
must be kept in sync by hand.

## 1. konet-server in dev

```bash
cd konet-server
mix setup          # deps.get + esbuild install + assets.build
mix phx.server     # http://localhost:4000
```

`mix setup` is an alias defined in `konet-server/mix.exs`; it runs
`deps.get`, `assets.setup` (`esbuild.install --if-missing`) and `assets.build`
(`esbuild konet`). The esbuild bundle is tiny — `assets/js/app.js` only wires up
the LiveView socket, since the Studio is server-rendered.

In dev (`config/dev.exs`):

- listens on `0.0.0.0:4000`;
- `check_origin: false` — any origin may open a WebSocket;
- `code_reloader: false` (deliberately off — no live reload on Elixir changes,
  restart the server);
- an esbuild `--watch` watcher rebuilds `assets/` on change;
- `secret_key_base` falls back to a hardcoded dev value.

Tests:

```bash
mix test
mix compile --warnings-as-errors   # what CI enforces
```

`config/test.exs` sets `server: false` and port 4002, and pins
`jwt_secret: "test-jwt-secret-at-least-32-characters!!"`. Tests run
`async: false` because they mutate `Application.put_env(:konet, …)` (see
`test/konet/rate_limiter_test.exs`).

### Dev in Docker

`konet-server/Dockerfile.dev` exists for a containerised dev loop
(`mix phx.server` with `inotify-tools`). It is **not** referenced by
`docker-compose.yml`, which builds the production `Dockerfile`. Use it manually:

```bash
docker build -f konet-server/Dockerfile.dev -t konet-dev konet-server
docker run -p 4000:4000 -v "$PWD/konet-server:/app" konet-dev
```

## 2. konet-cli

```bash
cd konet-cli
go build -o konet .     # or: go run . <command>
go vet ./...
go test ./...           # internal/config + the JWT signer in cmd/
```

Trying it out end to end, in a scratch directory:

```bash
mkdir /tmp/konet-try && cd /tmp/konet-try
/path/to/konet-cli/konet init            # writes konet.config.toml, generates the secrets
/path/to/konet-cli/konet keys generate   # mints anon_key + service_key
/path/to/konet-cli/konet start           # pulls ghcr.io/raucheacho/konet:latest, runs it
/path/to/konet-cli/konet status
/path/to/konet-cli/konet studio          # opens http://localhost:4000/studio
/path/to/konet-cli/konet stop
```

To exercise local server changes, build the image and point the CLI at it:

```bash
docker build -t konet-server:dev konet-server
konet start --image konet-server:dev     # or set [server].image in the config
```

`ImageExists` finds it locally and skips the pull. The image used to be a
hardcoded constant, so the CLI could only ever run server code that had already
shipped.

⚠️ **`mode = "native"` is not implemented** — `cmd/start.go` rejects it with a
message pointing at `mix phx.server`. Only `mode = "docker"` works.

## 3. The SDKs

```bash
# JavaScript — the reference implementation
cd sdk/js && npm ci && npm run typecheck && npm test && npm run build

# React Native — resolves the core from ../js, hence --legacy-peer-deps
cd sdk/react-native && npm ci --legacy-peer-deps && npm run typecheck && npm test && npm run build

# Go
cd sdk/go && go build ./... && go vet ./... && go test ./...

# Python
cd sdk/python && pip install -e '.[dev]' && pytest
```

CI runs all of these, including `go test -race` for `sdk/go` and `pytest` for
`sdk/python` — neither of which it did until recently, so both suites existed
without ever running there.

## 4. The live-room example

Needs a running server plus an `anon_key`.

```bash
# 1. server (either konet start, or mix phx.server with KONET_HISTORY_LIMIT set)
KONET_HISTORY_LIMIT=50 mix phx.server     # from konet-server/

# 2. web front-end
cd examples/live-room/web
npm install        # pulls the SDK through file:../../../sdk/js
npm run dev        # http://localhost:5173

# 3. Python agent / stress test
cd examples/live-room/agent
python -m venv .venv && source .venv/bin/activate
pip install -e ../../../sdk/python
KONET_TOKEN=<anon_key> AGENT_COUNT=20 python agent.py
```

The web app asks for the `anon_key` in its connect dialog and caches it in
`localStorage` under `konet_token`. The agent reads it from `KONET_TOKEN`.

`agent.py` knobs: `AGENT_COUNT`, `REACTION_SPEED`, `CURSOR_SPEED`,
`CHAT_SPEED`, `STAGGER`, `KONET_URL`. With the default `CURSOR_SPEED=0.1`, each
bot sends ~10 msg/s, so 20 bots ≈ 200 msg/s — above the default per-socket
`KONET_RATE_LIMIT=60`? No: the limit is *per socket*, and each bot has its own
socket, so each stays at ~12 msg/s. Turning `CURSOR_SPEED` below `0.017` will
start tripping the limiter.

The chat backlog (`konet:history`) only appears when the server runs with
`KONET_HISTORY_LIMIT > 0`. It is off by default. Through the CLI, set it in
`konet.config.toml`:

```toml
[history]
limit = 50
```

That used to be impossible — `konet start` could not pass the variable at all,
so the example's own README asked for something the CLI could not do.

## 4b. The conformance harness

Runs every SDK's scenario against a real server it starts itself:

```bash
./conformance/run.sh
```

It uses port 4009 and its own secret, so it can run alongside a development
server. See [`conformance/README.md`](../conformance/README.md) for the 15 steps
and how to add a language.

## 5. The public docs site (for reference)

```bash
cd docs && bun install && bun run dev   # http://localhost:3000
```

`bun run build` produces the static export in `docs/out/`. Do not edit either
from a docs-internal task.

## Environment variables

Every variable is read in `konet-server/config/runtime.exs`. `:prod` and `:dev`
have separate blocks — a variable present in one and not the other simply has no
effect there.

| Variable | Required | Default | Read in | Purpose |
|---|---|---|---|---|
| `SECRET_KEY_BASE` | **yes in prod** (raises) | dev fallback string | prod + dev | Phoenix cookie/session signing. Not the JWT secret. |
| `KONET_JWT_SECRET` | **yes in prod** (raises) | `dev.exs` value in dev | prod + dev | HMAC-SHA256 key for every JWT (anon, service, user tokens). |
| `KONET_HOST` | no | `localhost` | prod only | Public hostname used in generated URLs (`url: [host: …, port: 443, scheme: "https"]`). |
| `KONET_PORT` | no | `4000` | prod only | HTTP listen port. |
| `KONET_ANON_KEY` | no | `nil` | prod only | Pre-minted public token, displayed in Studio → Keys. |
| `KONET_SERVICE_KEY` | no | `nil` | prod only | Pre-minted admin token; required by every `/api/*` admin route. |
| `KONET_STUDIO_PASSWORD` | no | `nil` | prod + dev | Studio password. **Unset means the Studio has no login at all.** |
| `KONET_ALLOWED_ORIGINS` | no | `*` | prod only | WebSocket origin check. `*`/empty → `check_origin: false`; otherwise a comma-separated list. |
| `KONET_RATE_LIMIT` | no | `60` | prod + dev | Broadcasts per second per socket. |
| `KONET_CONN_RATE_LIMIT` | no | `200` | prod + dev | New connections per minute per IP. |
| `KONET_RATE_LIMIT_BINARY` | no | `120` | prod + dev | Binary frames per second per socket (50 fps for 20 ms Opus plus headroom). |
| `KONET_FLOOR_MAX_HOLD_MS` | no | `30000` | prod + dev | How long a floor may be held before `Konet.Floor` sweeps it. |
| `KONET_HISTORY_LIMIT` | no | `0` (disabled) | prod + dev | Broadcasts buffered per room for late joiners. |
| `KONET_HISTORY_TTL` | no | `900` | prod + dev | Seconds a room's buffer outlives its last message. Bounds the table for many short-lived rooms. |
| `KONET_TRUST_PROXY_HEADERS` | no | `false` | prod + dev | Read the client IP from `X-Forwarded-For`. **Set it only when a proxy really is in front** — see below. |
| `KONET_LOG_BROADCASTS` | no | `true` | prod + dev | Write an entry to the Studio Logs page per accepted broadcast. `false` for high-throughput deployments. |
| `KONET_WEBHOOK_URL` | no | `nil` | prod + dev | POST target for channel lifecycle events. Empty disables webhooks. |
| `KONET_WEBHOOK_SECRET` | no | `nil` | prod + dev | When set, requests carry `x-konet-signature: sha256=<hex>`. |
| `MIX_ENV` / `PHX_SERVER` | set by the image | `prod` / `true` | Dockerfile | The release only starts the endpoint when `PHX_SERVER=true`. |
| `ERL_FLAGS` | set by the image | `+JMsingle true` | Dockerfile builder stage | Works around the BEAM JIT under QEMU during multi-arch builds. |

Note that `KONET_HOST`, `KONET_PORT`, `KONET_ANON_KEY`, `KONET_SERVICE_KEY` and
`KONET_ALLOWED_ORIGINS` are only read in the `:prod` block. Running
`mix phx.server` in dev ignores them.

**`KONET_TRUST_PROXY_HEADERS` cuts both ways.** Off, every connection behind a
reverse proxy carries the proxy's IP, so `KONET_CONN_RATE_LIMIT` becomes one
global budget and a busy deployment rate-limits itself. On without a proxy, a
client can forge `X-Forwarded-For` and mint itself a private budget. Set it
exactly when something in front of Konet is rewriting that header.

### Generating them

```bash
# KONET_JWT_SECRET — 32 random bytes, hex
openssl rand -hex 32

# SECRET_KEY_BASE — Phoenix wants at least 64 bytes
mix phx.gen.secret          # from konet-server/
# or, without Elixir:
openssl rand -base64 64 | tr -d '\n'

# KONET_STUDIO_PASSWORD — anything; it is compared with Plug.Crypto.secure_compare
openssl rand -base64 24
```

`KONET_ANON_KEY` and `KONET_SERVICE_KEY` are **derived**, not random: they are
JWTs signed with `KONET_JWT_SECRET`. Three ways to get them:

1. `konet keys generate` — the CLI signs them itself in
   `konet-cli/cmd/keys.go` (`signJWT`, a hand-rolled HS256 implementation) and
   writes them back into `konet.config.toml`.
2. Studio → Keys → **Rotate Secret** — `Konet.Auth.rotate!/0` generates a new
   `jwt_secret` and re-signs both keys.
   ⚠️ It only calls `Application.put_env/3`; the values live in the running
   process and are **lost on restart** unless you copy them into your env.
   Rotating also invalidates every previously issued token, including the ones
   your clients hold.
3. Sign them yourself — any HS256 JWT with `{"role": "anon"}` or
   `{"role": "service"}` and the right secret is accepted.

### Token claims the server understands

Handled in `KonetWeb.UserSocket.connect/3` and `KonetWeb.RoomChannel`:

| Claim | Effect |
|---|---|
| `role` | `"service"` unlocks `/api/*` admin routes; anything else is a regular client. Stored in presence metadata. |
| `sub` | Becomes `socket.assigns.user_id`; falls back to `"anon_<socket_id>"`. It is the presence key and the floor holder id. |
| `channels` | Optional list of allowed topics. Absent → the token may join any room. Entries may end in `*` for prefix matching (`"room:user-42:*"`). |
| `exp` | Enforced **only when present** — see `Konet.Auth.token_config/0`. Tokens minted by `sign/1` carry no `exp`, and making it mandatory would break every deployment on upgrade. |
| `iat` | Added automatically by `Konet.Auth.sign/1`. Not validated. |

### Local secrets file

The repo root has a gitignored `.env.local` (`.gitignore` matches `.env.*`)
holding a working set of values for `docker compose`. It is a convenience file,
not a template — the tracked template is `konet-server/.env.example`. Never
commit real values.
