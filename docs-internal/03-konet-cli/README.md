# 03 — konet-cli

| File | Contents |
|---|---|
| [00-commands.md](00-commands.md) | Cobra command tree, what each one does, `konet.config.toml` |
| [01-server-communication.md](01-server-communication.md) | Docker API, HTTP admin API, generated files |
| [02-release-goreleaser.md](02-release-goreleaser.md) | From a git tag to a published binary |

## Scope, in one paragraph

`konet-cli` is a **local development** tool, on the Supabase-CLI model. It
starts one Docker container on the developer's machine, mints keys, tails logs
and opens the Studio. It is not a production orchestrator, has no notion of
remote hosts, environments or deployments, and never will — production is
docker-compose, Coolify or Dokploy (see [../05-deployment.md](../05-deployment.md)).

## Layout

```
konet-cli/
├── main.go               3 lines: cmd.Execute()
├── cmd/                  one file per command, Cobra
│   ├── root.go           rootCmd, AddCommand of the 10 commands
│   ├── init.go  keys.go  start.go  stop.go  status.go
│   ├── logs.go  channels.go  publish.go  studio.go  upgrade.go
├── internal/
│   ├── config/           konet.config.toml (BurntSushi/toml) + GenerateSecret
│   ├── docker/           docker/docker client wrapper
│   └── api/              HTTP client for /api/*
├── .goreleaser.yaml      build + archives + Homebrew cask + Scoop bucket
├── LICENSE               a COPY of the root LICENSE — see 02-release-goreleaser.md
└── README.md             a copy of the root README, shipped inside the archives
```

Dependencies (`go.mod`, Go **1.25.0**): `spf13/cobra`, `BurntSushi/toml`,
`docker/docker`, `docker/go-connections`. Nothing else direct.
