# 05 — Deployment

Three ways to run Konet, in increasing order of permanence:

| | Who starts it | Config source | Intended for |
|---|---|---|---|
| `konet start` | the CLI, via the Docker API | `konet.config.toml` | local development |
| `docker run` | you | `-e` flags | a quick VPS test |
| `docker-compose.yml` | compose, Coolify, Dokploy | `.env` + platform env vars | production self-hosting |

## The image

`konet-server/Dockerfile`, a two-stage build.

**Builder** — `hexpm/elixir:1.16.3-erlang-26.2.5-debian-bookworm-20240612-slim`:

```dockerfile
ENV MIX_ENV=prod
ENV ERL_FLAGS="+JMsingle true"      # QEMU workaround, see below

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile              # ← cached: deps recompile only when deps change
COPY assets/package.json assets/package.json
RUN npm install --prefix assets
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.deploy             # esbuild --minify + phx.digest
RUN mix compile
RUN mix release
```

The layer ordering is doing real work: deps are fetched and compiled before
`lib/` is copied, so an application-code change does not recompile the
dependency tree. Note `config/dev.exs` and `config/test.exs` are **not** copied —
`mix release` under `MIX_ENV=prod` never reads them, and leaving them out keeps
dev secrets out of the image.

**Runner** — `debian:bookworm-slim` with `libstdc++6`, `openssl`, `libncurses5`,
`locales`, `ca-certificates` and **`curl`** (the healthcheck needs it), running
as `nobody`:

```dockerfile
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/konet ./
ENV MIX_ENV=prod
ENV PHX_SERVER=true
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1
CMD ["/app/bin/konet", "start"]
```

`PHX_SERVER=true` is what makes the release actually start the endpoint (a Mix
release does not, by default).

## `docker-compose.yml`, service by service

There is exactly one service and one network.

```yaml
services:
  konet-server:
    build:
      context: ./konet-server
      dockerfile: Dockerfile
    image: ghcr.io/raucheacho/konet:latest
    container_name: konet-server
    restart: unless-stopped
    ports:
      - "${KONET_PORT:-4000}:4000"
```

- **`build` + `image` together** is deliberate: `docker compose up` from a clone
  builds locally and tags the result; a platform that only pulls (Coolify/Dokploy
  pointed at the image) uses the published tag. Either path works from the same
  file.
- **`container_name: konet-server`** matches `docker.ContainerName` in the CLI,
  so `konet stop`/`logs`/`status` can drive a compose-started container too.
  It also means two compose projects cannot coexist on one host.
- **`ports: "${KONET_PORT:-4000}:4000"`** — the *host* side is configurable, the
  *container* side is fixed at 4000. This differs from the CLI, which uses the
  same number on both sides.

Environment block, grouped by role:

| Key | Value in the file | Notes |
|---|---|---|
| `MIX_ENV` | `prod` | fixed |
| `PHX_SERVER` | `"true"` | fixed — without it the release starts no endpoint |
| `KONET_HOST` | `${KONET_HOST:-localhost}` | public hostname used in generated URLs; set it to your domain |
| `KONET_PORT` | `"4000"` | the **container** port, always 4000 |
| `KONET_JWT_SECRET` | `${KONET_JWT_SECRET:?…required}` | `:?` — compose **fails fast** if unset |
| `SECRET_KEY_BASE` | `${SECRET_KEY_BASE:?…required}` | same |
| `KONET_ANON_KEY` / `KONET_SERVICE_KEY` | `${…:-}` | optional; empty is valid |
| `KONET_STUDIO_PASSWORD` | `${…:-}` | **empty means no Studio login** |
| `KONET_ALLOWED_ORIGINS` | `${…:-*}` | `*` disables the WebSocket origin check |
| `KONET_RATE_LIMIT` | `${…:-60}` | broadcasts/s per socket |
| `KONET_CONN_RATE_LIMIT` | `${…:-200}` | connections/min per IP |
| `KONET_RATE_LIMIT_BINARY` | `${…:-120}` | binary frames/s per socket |
| `KONET_FLOOR_MAX_HOLD_MS` | `${…:-30000}` | how long one member may hold the floor |
| `KONET_TRUST_PROXY_HEADERS` | `${…:-false}` | **set this behind Coolify/Dokploy/Traefik/Nginx** — see below |
| `KONET_HISTORY_LIMIT` | `${…:-0}` | replay off by default |
| `KONET_HISTORY_TTL` | `${…:-900}` | seconds a room's buffer outlives its last message |
| `KONET_LOG_BROADCASTS` | `${…:-true}` | per-broadcast Studio logging; `false` under load |
| `KONET_WEBHOOK_URL` / `KONET_WEBHOOK_SECRET` | `${…:-}` | optional |

Every variable `runtime.exs` reads is now listed with its default.
`KONET_RATE_LIMIT_BINARY` and `KONET_FLOOR_MAX_HOLD_MS` used to work only if you
happened to know they existed — Docker passes through anything in the
environment, but they were undiscoverable from the file itself.

Healthcheck and network:

```yaml
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/api/health"]
      interval: 30s   timeout: 10s   retries: 3   start_period: 30s
    networks: [konet]
networks:
  konet: { driver: bridge }
```

The healthcheck duplicates the one baked into the image. Redundant but harmless,
and it means the compose file works against an image built elsewhere.

## Local (CLI) vs self-hosted — what actually differs

| | `konet start` | compose / Coolify / Dokploy |
|---|---|---|
| Image | `[server].image` or `--image`, default `ghcr.io/raucheacho/konet:latest` | whatever you point at; can build locally |
| Port mapping | same number both sides (`5000:5000`) | host side configurable, container side fixed at 4000 |
| Bind address | `0.0.0.0` on the host, always | up to the platform |
| Env vars available | all of them, via `Config.ServerEnv()` | all of them |
| History / origins / webhooks / rate limits | `[history]`, `[server].allowed_origins`, `[webhooks]`, `[limits]` | env vars |
| Secrets | `konet.config.toml`, plaintext next to your code | `.env` or the platform's secret store |
| `SECRET_KEY_BASE` | generated at `init` and persisted | you must supply it |
| Readiness | polls `/api/health` up to 60 s | healthcheck-driven |
| Restart policy | `unless-stopped` | `unless-stopped` |
| TLS | none | your reverse proxy |

A production configuration is now reproducible locally — `konet start` used to
pass a hardcoded set of eight variables, which put history replay, origin
checking, the rate limits and webhooks out of reach entirely. TLS and the host
port mapping remain the real differences.

## Reverse proxies

Konet speaks plain HTTP on 4000 and expects TLS termination in front. Two things
must be right, always:

1. **WebSocket upgrade headers.** Caddy and Traefik do it automatically; Nginx
   needs it spelled out:

   ```nginx
   location / {
       proxy_pass http://127.0.0.1:4000;
       proxy_http_version 1.1;
       proxy_set_header Upgrade $http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header Host $host;
   }
   ```

2. **Long-lived connections.** The default proxy read timeout in Nginx is 60 s,
   which is longer than the 30 s SDK heartbeat, so idle sockets survive — but
   only just. Raise `proxy_read_timeout` if you change the heartbeat interval.

⚠️ **Set `KONET_TRUST_PROXY_HEADERS=true` behind a proxy.** Without it,
`UserSocket.extract_ip/1` sees only the proxy's address, so
`KONET_CONN_RATE_LIMIT` (default 200/min) is one **global** budget and a
moderately busy deployment rate-limits *itself*. With it, the leftmost
`X-Forwarded-For` entry is used instead.

Leave it off when clients connect directly: the header is then attacker-supplied,
and trusting it hands every client its own private budget. Konet cannot detect
which case it is in, so this is the one proxy setting you must state explicitly.

### Coolify

1. **New Resource → Docker Image**, `ghcr.io/raucheacho/konet:latest`, or a
   Docker Compose resource pointed at this repo's `docker-compose.yml`.
2. Set the env vars in the resource's Environment Variables. `KONET_JWT_SECRET`
   and `SECRET_KEY_BASE` are mandatory.
3. Exposed port `4000`, attach your domain — Coolify's Traefik handles TLS and
   WebSocket upgrades out of the box. **Do not hand-write Traefik labels**; see
   the history section below.
4. Deploy. The image's built-in healthcheck on `/api/health` gives Coolify real
   health status.

### Dokploy

Create Application → Docker (image) with the same image, or Compose pointed at
the repo. Add the env vars, map the domain to container port `4000`.

### Plain VPS

```bash
curl -O https://raw.githubusercontent.com/raucheacho/konet/main/docker-compose.yml
cat > .env <<EOF
KONET_JWT_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 32)
KONET_STUDIO_PASSWORD=$(openssl rand -base64 24)
KONET_ALLOWED_ORIGINS=https://app.example.com
EOF
docker compose up -d
```

⚠️ `openssl rand -hex 32` gives 64 characters, which satisfies Phoenix's
`secret_key_base` requirement. Do not shorten it.

### After first boot

1. Open `https://your-domain/studio`, sign in with `KONET_STUDIO_PASSWORD`.
2. Keys → **Rotate Secret** to mint anon/service keys, **or** pre-set
   `KONET_ANON_KEY`/`KONET_SERVICE_KEY`.
3. If you rotated: copy the new values back into the platform's env settings
   *immediately*. The rotation lives only in the running process
   (`Application.put_env`) and a restart reverts to the old secret, locking out
   any client that saved the new key.

## What has gone wrong before, and where it stands

### `SECRET_KEY_BASE` / `KONET_JWT_SECRET` interpolation

The compose file uses `${VAR:?message}` for both, which makes `docker compose
up` **fail immediately with a readable message** rather than starting a
container that raises in `runtime.exs` and restart-loops. That is the current
state and it is the right one.

Two related traps remain:

- **`SECRET_KEY_BASE` values containing `$`** get interpolated by compose. The
  `.env.local` in this repo holds a base64 value ending in `==` — safe — but
  `openssl rand -base64` can emit `$`, and compose will eat it. Prefer
  `openssl rand -hex 32`.
- **Coolify and Dokploy do their own interpolation** on env values before
  compose sees them. A literal `$` in a secret can be mangled twice.

### `ports:` vs `expose:`

The compose file flip-flopped: commit `05bb68b` ("corrige le compose") changed
`ports:` to `expose: ["${KONET_PORT}"]` so the container would sit behind the
platform's proxy without publishing a host port; commit `5d41bed` ("version prod
ok") reverted to `ports: "${KONET_PORT:-4000}:4000"`.

The revert is correct for the general case — `expose` publishes nothing, so a
plain `docker compose up` on a VPS became unreachable, and `${KONET_PORT}` with
no default made the file fail outright when the variable was unset. If you are
on Coolify/Dokploy with an attached domain, the published host port is redundant
but harmless; drop it with an override file if you want the port closed:

```yaml
# docker-compose.override.yml  (gitignored)
services:
  konet-server:
    ports: !reset []
    expose: ["4000"]
```

Same commit also dropped the obsolete `version: "3.9"` key.

### Traefik labels

State of the repo today: **`docker-compose.yml` contains no Traefik labels**,
and the only mentions of Traefik anywhere are in the public docs
(`docs/pages/server/deployment.mdx`, `docs/pages/server/configuration.mdx`),
where it appears as "Coolify's Traefik handles TLS and WebSocket upgrades out of
the box" and "put Nginx/Caddy/Traefik in front for TLS" in the plain-VPS
section. There is no commit in this repo's history that adds and then removes
Traefik labels, so if labels caused a deployment incident it happened in a
platform's own config, not in a tracked file. Treat the guidance below as the
rule to keep, not as a reconstruction of a fix.

The rule: **do not add Traefik labels to the tracked compose file.** Coolify and
Dokploy generate their own router/service labels from the domain you attach in
their UI. Hand-written labels collide with the generated ones — duplicate
routers, a service pointing at the wrong port, or a router with no TLS resolver.
Both platforms only need the exposed port (`4000`) and the domain.

If you run Traefik yourself, without a PaaS, add labels through
`docker-compose.override.yml` (already gitignored) rather than editing the
tracked file, and make sure
`traefik.http.services.<name>.loadbalancer.server.port=4000` points at the
**container** port, not the published host port.

### `mix assets.deploy` in the image

`assets.deploy` is `esbuild konet --minify` + `phx.digest`. Two things made this
fragile and both are handled now:

- **Node must exist in the builder.** The Dockerfile installs
  `nodesource setup_20.x` explicitly, because the hexpm Elixir image has no
  Node and `esbuild` needs one for `npm install --prefix assets`.
- **`priv/static/assets/` is gitignored**, so the image cannot rely on committed
  build output — `COPY priv priv` brings an assets-less `priv/`, and
  `mix assets.deploy` fills it. Running `mix release` without
  `mix assets.deploy` first produces a Studio with no CSS. The step order in the
  Dockerfile (`assets.deploy` → `compile` → `release`) is load-bearing.

### Multi-arch build crashing under QEMU

`release-server.yml` builds `linux/amd64,linux/arm64` on an amd64 runner, so the
arm64 build runs under QEMU. The BEAM's JIT dual-maps code memory, which QEMU
cannot emulate, and `mix compile` crashed. Fixed in commit `4d891e5` with a
single line in the **builder** stage:

```dockerfile
ENV ERL_FLAGS="+JMsingle true"
```

It is scoped to the builder, so the released runtime keeps the normal JIT
behaviour.

### GHCR tag rules

`docker/metadata-action` in `release-server.yml` emits `latest` from two rules —
`enable={{is_default_branch}}` and `enable=${{ startsWith(github.ref, 'refs/tags/v') }}`.
Tag pushes are not on a branch, so without the second rule a tagged release
would publish `0.3.0` and `0.3` but never move `latest` — and `konet start`,
which hardcodes `:latest`, would keep pulling an old image.
