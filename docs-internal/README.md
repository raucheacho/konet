# docs-internal — contributor documentation

**Internal** documentation for Konet: how the monorepo is put together, how to
run it locally, and where the traps are.

> Not to be confused with `docs/`, which is the **public Nextra site**
> (https://raucheacho.github.io/konet/) aimed at people who *use* Konet in their
> application. Neither `docs/` nor `docs/out/` should ever be edited from here.

| File | Contents |
|---|---|
| [00-overview.md](00-overview.md) | What each piece does, how they fit together, why Phoenix and why Go |
| [01-getting-started.md](01-getting-started.md) | Full local setup, tool versions, environment variables |
| [02-konet-server/](02-konet-server/) | Phoenix architecture, channels, binary frames, auth, Studio, metrics |
| [03-konet-cli/](03-konet-cli/) | Go commands, how the CLI talks to the server, GoReleaser pipeline |
| [04-sdk/](04-sdk/) | One file per language plus the contract shared by all SDKs |
| [05-deployment.md](05-deployment.md) | docker-compose service by service, self-hosting, history of past breakage |
| [06-known-issues.md](06-known-issues.md) | Known bugs, technical debt, CI/prod traps |
| [07-glossary.md](07-glossary.md) | Konet vocabulary |

Related, outside this folder: [`../conformance/`](../conformance/) runs every
SDK's scenario against a real server — the only test that checks the two halves
of the protocol against each other.

## Reading convention

Blocks marked **⚠️ Fragile** flag code that works but rests on an implicit
invariant, or a workaround that is already in place. They are all collected in
one place in [06-known-issues.md](06-known-issues.md).
