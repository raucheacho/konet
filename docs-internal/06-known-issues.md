# 06 — Known issues, technical debt, traps

Status legend: **open** (unfixed), **mitigated** (root cause remains but the
damage is bounded or switchable), **by design** (a real constraint, documented
so nobody "fixes" it by accident).

A large batch of the issues originally recorded here has been fixed; they are
listed in [Fixed](#fixed--kept-so-nobody-re-introduces-them) at the bottom with
the behaviour that now pins them. Do not delete that table — several of these
bugs are the kind that grow back.

---

## Open

### 1. Single node only — **by design**

Nothing forms a BEAM cluster. `Phoenix.PubSub` stays local and no ETS state is
replicated, so two instances behind a load balancer would not share presence,
channels or floors — and `Konet.Floor` would grant the same topic to one holder
per node, which is a correctness failure rather than a scaling one.

This is the one item here that is a **feature, not a defect**: making it
multi-node means `libcluster`, a distributed PubSub adapter, and re-deriving
floor arbitration from "the ETS table is the only authority" to something
cluster-wide. That is a design change with its own trade-offs, and the project's
stated goal is to avoid overengineering, so it is left explicit rather than
half-built. Scale up, not out, until there is a reason.

### 2. `mode = "native"` does not exist — **open**, cosmetic

`config.ServerConfig.Mode` is kept because existing config files carry it, and
`cmd/start.go` rejects anything but `docker` with a message pointing at
`mix phx.server`. The field itself could go once no config in the wild sets it.

### 3. `install.sh` is not yet on `main` — **open until merged**

`konet upgrade` fetches
`https://raw.githubusercontent.com/raucheacho/konet/main/install.sh` when it is
allowed to self-update at all. The script exists in this tree and is verified
end to end against the published v0.3.0 release (download → checksum → extract →
install → run), but the URL only resolves once it lands on `main`. Until then
`upgrade` takes its fallback path and prints the releases page — correct
behaviour, unlike the old one of piping a 404 page to `sh`.

Note this only affects installs that *no package manager owns*. On Homebrew or
Scoop the command never touches the network path at all; see below.

### 3b. Distribution: who owns the binary — **resolved by construction**

The intended paths are Homebrew (macOS/Linux) and Scoop (Windows) for the CLI,
and the Docker image for the server. `install.sh` exists for the remaining case:
Linux without brew, or a CI image that wants the binary.

Divergence between the two is prevented from both sides, because a self-update
over a managed install leaves that manager's metadata describing a file it no
longer controls — `brew list --versions` says one thing, `konet --version`
another, and the next `brew upgrade` silently reverts whatever was written:

* **`konet upgrade`** resolves its own path through symlinks and classifies it
  (`Caskroom`/`Cellar`/`linuxbrew` → Homebrew, `scoop/apps` → Scoop, otherwise
  unmanaged). On a managed install it prints `brew upgrade --cask konet` or
  `scoop update konet` and does nothing else. The classification happens
  **before** the network call, so a rate-limited GitHub API cannot turn that
  advice into an error.
* **`install.sh`** refuses to run when `brew list --cask konet` or
  `scoop list konet` succeeds, and defaults to `~/.local/bin` rather than
  `/usr/local/bin` — which on Intel macOS *is* Homebrew's prefix, so the old
  default collided with brew by construction.

Pinned by `cmd/upgrade_test.go` (8 cases including the Caskroom symlink, which
is the one that matters: brew links the binary into its bin directory, so the
unresolved path looks ordinary and reveals nothing).

### 4. Committed JS/RN package versions are meaningless — **by design**

`sdk/js/package.json` and `sdk/react-native/package.json` both say `0.1.0` and
are rewritten from the git tag at release. The RN `peerDependencies: ">=0.3.0"`
is the only version constraint in those files that is real.

Python and the server are no longer in this category: the Python release
rewrites `__version__`, and the server derives its version from the
`KONET_VERSION` build arg.

### 5. Webhook ordering is not guaranteed — **by design**

Each event is its own supervised task, and a retry pushes one further back, so
`member_joined` and `member_left` for the same user can arrive out of order.
Delivery is at-least-once. Receivers must be idempotent; every request carries a
stable `id` for exactly that.

### 6. Per-broadcast Studio logging is on by default — **mitigated (switchable)**

`RoomChannel` writes to `Konet.LogBuffer` on every accepted broadcast, which
makes that one GenServer the serialization point under load. Kept on because the
Studio Logs page is most of its value; set `KONET_LOG_BROADCASTS=false` for
high-throughput deployments. The binary path never logged and still does not.

### 7. The conformance harness does not cover React Native — **open**

`sdk/react-native` is a thin subclass of the JS core that adds `AppState`
handling, and the scenario needs a React Native runtime to exercise it. The
protocol it speaks is the core's, which *is* covered.

### 8. No SDK asserts the `konet:floor` broadcast shape in isolation — **partly closed**

The conformance harness asserts it against a real server (step 7), so a change
would be caught. No SDK's own unit tests assert it, which matters only if the
harness is skipped.

## Fixed — kept so nobody re-introduces them

Each row names the behaviour that now holds it in place. Where a test exists,
that test *is* the guard.

### SDKs

| Was | Now | Pinned by |
|---|---|---|
| **Python: reconnect never re-joined channels.** The client looked connected while every send landed on a topic the socket had never joined — and since Konet only replies to *refused* broadcasts, nothing errored. | `Channel._wants_join` / `_rejoin()` / `_socket_closed()`, re-issued from `KonetClient._reconnect` | `tests/test_reconnect.py::test_rejoins_after_a_dropped_connection`, `::test_does_not_rejoin_a_channel_that_was_left`, `::test_send_fails_loudly_while_disconnected` |
| **Python: a failed reconnect left `_ws = None` and busy-looped at 10 Hz forever.** | `_reconnect` owns the backoff and returns false when exhausted, ending the read loop | `::test_gives_up_after_max_tries_instead_of_spinning` |
| **Python: heartbeat replies were discarded, so a locally-open dead socket was never noticed.** | `_pending_heartbeat_ref` + a `heartbeat_timeout` deadline; an unanswered probe closes the socket and the read loop reconnects | `::test_unanswered_heartbeat_forces_a_reconnect`, `::test_answered_heartbeat_keeps_the_socket` |
| **Python: in-flight replies sat on their 10 s timeout after a drop.** | `_socket_closed` fails pending futures with `ConnectionError` | `::test_pending_replies_fail_instead_of_hanging` |
| **Go: every reconnect spawned a fresh `heartbeatLoop` that only `Disconnect` could stop**, so the client sent one extra heartbeat per interval per reconnect. | loops are spawned once, guarded by `Client.started`; `reconnect` reuses them | `client_test.go::TestNoGoroutineLeakAcrossReconnects` |
| **Go: an abandoned connection was never closed**, leaking the websocket library's per-connection goroutine. | `reconnect` calls `CloseNow()` on the old conn | same test |
| **Go: data race on `Channel.state`** — read and written in `reconnect` without the mutex. | all state access under `Channel.mu`; `Joined()` accessor | `go test -race`, now in CI |
| **Go: `On()` compared handlers with `fmt.Sprintf("%p", h)`** (matches distinct closures sharing a body) and **`OnBinary()` captured a slice index** (shifted by earlier removals). | both use an explicit `id` on `eventSub`/`binarySub` | `::TestUnsubscribeRemovesOnlyItsOwnHandler`, `::TestBinaryUnsubscribeRemovesOnlyItsOwnHandler` |
| **Go: no liveness detection** — heartbeat replies skipped with the rest of the `"phoenix"` topic. | `pendingHeartbeat` tracked; an unanswered probe closes the conn so the read loop reconnects | `::TestUnansweredHeartbeatForcesReconnect`, `::TestAnsweredHeartbeatKeepsTheSocket` |
| **Go: the token was interpolated into the URL unescaped.** | `url.QueryEscape` | — |
| **Go: `Disconnect` closed `done` under a select/default race.** | `sync.Once` | — |
| JS: did not re-join after a reconnect | `wantsJoin` + `_rejoin()` from `onopen` | 4 tests in `describe("reconnect")` |

### Server

| Was | Now | Pinned by |
|---|---|---|
| **`Metrics.connections` under-counted.** Incremented once per socket, decremented once per *channel*, so a client in three rooms decremented three times and the gauge drifted to zero. Wrong in the Studio, `/metrics`, `/api/health` and `konet status` simultaneously. | `Konet.Metrics` monitors the socket process; `RoomChannel.terminate/2` no longer touches it | `test/konet/metrics_test.exs`, incl. `"leaving channels does not decrement the connection count"` |
| **Connection rate limiting was inert behind any reverse proxy** — every connection carried the proxy's IP, so `KONET_CONN_RATE_LIMIT` was one global budget and busy deployments rate-limited themselves. | `KONET_TRUST_PROXY_HEADERS` opts into the leftmost `X-Forwarded-For` entry; off by default, because trusting it unconditionally lets a direct client forge a private budget | `test/konet_web/user_socket_test.exs` (5 tests, both directions) |
| **CORS and the WebSocket origin check disagreed** — `check_origin` honoured `KONET_ALLOWED_ORIGINS` while `plug Corsica, origins: "*"` was hardcoded. | both read the same list via `KonetWeb.Cors.allowed?/1` | `test/konet_web/cors_test.exs` |
| **`Konet.History` never evicted rooms**, growing unbounded on workloads that mint many short-lived room names. | TTL sweep (`KONET_HISTORY_TTL`, default 900 s). Deliberately age-based, never occupancy-based: outliving the room emptying is the entire point of the buffer | `test/konet/history_test.exs`, incl. `"a room's buffer outlives the room emptying"` |
| **`Floor.acquire/3` recursed without bound** on a contended release/acquire interleaving. | bounded to `@max_acquire_attempts`, then reports the holder | `test/konet/floor_test.exs` |
| **`Floor` accumulated one monitor per press** — never demonitored. | `release`/sweep drop the monitor; re-acquiring replaces it | `::"releasing drops the monitor, so repeated presses do not accumulate"` |
| **`konet:floor` announced `since: now`, mixing a wall clock with `Floor`'s monotonic one.** | `acquire` returns the real acquisition time as wall-clock ms; a duplicate press reports the *original* moment, which is what a mid-stream listener needs | `::"a duplicate press reports the original acquisition, not now"` |
| **`Floor` and `History` sweeps used a strict `<`**, so a TTL or max-hold of 0 never expired anything written in the current millisecond. | `=<` in both match specs | the two sweep tests |
| **The Studio loaded Google Fonts** — the server's only outbound network dependency, blocking the login page on air-gapped deployments. | removed from both the login page and the root layout; `app.css` uses platform font stacks | — |
| **`/api/health`, `/`, and the Studio reported a hardcoded `"0.1.0"`** on every release. | `Konet.Version.current/0`, from the `KONET_VERSION` build arg the release workflow passes | verified end to end (`KONET_VERSION=0.3.0` → `/api/health` reports `0.3.0`) |
| **`KonetWeb.Telemetry.metrics/0` was dead code** — no reporter, and `periodic_measurements/0` returned `[]`. | the poller dispatches `[:konet, :server]` every 10 s; `metrics/0` declares matching `last_value`/`counter` definitions | — |

### CLI

| Was | Now | Pinned by |
|---|---|---|
| **`-X main.version` was a silent no-op** — `main.go` had no `version` variable, so every released binary reported `0.1.0` and `konet upgrade` always believed an update existed. | `var version` in `main.go` → `cmd.SetVersion` | verified: `go build -ldflags "-X main.version=0.3.0"` reports `0.3.0` |
| **`konet upgrade` fetched a non-existent `install.sh` and piped GitHub's 404 page to `sh`** — `downloadScript` checked only transport errors. | `httpGet` rejects non-2xx, `downloadScript` rejects anything not starting like a shell script, dev builds skip self-update, fallback URLs corrected | — |
| **`konet start` could set only 8 env vars**, leaving history, origins, rate limits and webhooks unreachable — so a production config could not be reproduced locally. | `[limits]`, `[history]`, `[webhooks]`, `[server].allowed_origins` in `konet.config.toml` → `Config.ServerEnv()` | — |
| **`konet start` could only run the published image**, so the CLI could never exercise unshipped server changes. | `[server].image` plus a `--image` flag | — |
| **`konet start` slept a flat 20 s** instead of probing readiness. | polls `/api/health` every 250 ms up to 60 s, then fails with a message pointing at `konet logs` | — |
| **A stopped-but-present container made `ContainerCreate` fail** with a name conflict that did not mention `docker rm`. | `removeIfExists` clears it first; `find` matches the exact name rather than the substring the filter returns | — |
| **`konet logs` printed Docker's 8-byte stream headers inline.** | `stdcopy.StdCopy` | — |
| **`konet init` wrote the placeholder `jwt_secret` and non-JWT `kt_anon_xxx` keys**, so a server started before `keys generate` received tokens it could only reject. | generates a real random secret; leaves the keys empty and warns at `start` | — |
| **The hand-rolled HS256 signer had no test**, though it must stay byte-compatible with Joken. | `cmd/keys_test.go` states the JWT wire format independently; compatibility also verified against the running server | `cmd/keys_test.go` |
| **`konet logs` had dead code** (both branches of an `if` identical). | bound to the command's context | — |
| `internal/api` implemented `Presence()` with no command behind it | `konet presence <channel>` | — |

### Second round — the items originally left open

| Was | Now | Pinned by |
|---|---|---|
| **ETS tables died with their GenServer.** Created in each worker's `init/1`, so a crash recreated them empty: `Floor` silently freed every held floor, and `ChannelRegistry`'s channel list emptied while sockets were still connected and **never recovered**. | `Konet.Tables` owns all four, `:public`, and does nothing else — it has no callback that can fail. `Konet.Floor` also rebuilds its monitors from the table on restart, and drops rows whose holder died during the outage. | `test/konet/tables_test.exs` — kills each worker and asserts the data survives |
| **Three worker crashes in five seconds killed the whole node.** The `:one_for_one` default intensity, found by the tests above. | `max_restarts: 10, max_seconds: 10` — tolerant of a burst, still gives up on a genuine crash loop, where dying and letting the container restart is right | the same suite, which could not otherwise run |
| **Studio key rotation was in-memory only.** A restart reverted to the old secret, locking out any client that stored the new anon key. | `KONET_SECRET_FILE`: rotation writes the secret (mode 0600) and boot reads it back. `rotate!/0` returns `persisted:`/`error:`, and the Studio banner says which of the three outcomes happened instead of always claiming success. | `auth_test.exs` "rotate!/0 persistence" (4 tests), verified end to end across a restart |
| **The `:dev` JWT secret defaulted to a string published in this repository.** A dev server reachable from outside localhost accepted tokens anyone could mint. | dev generates a random secret per run when neither `KONET_SECRET_FILE` nor `KONET_JWT_SECRET` is set, and says so loudly on stderr | manual: booting dev with no secret prints the warning and a fresh secret |
| **`KONET_PORT`/`KONET_HOST` were read only in `:prod`**, so a second server from source meant editing `dev.exs`. | both honoured in the `:dev` block too | the conformance harness depends on it |
| **Webhook failures were logged and dropped**, so a receiver restarting lost the events. | bounded exponential retry (`KONET_WEBHOOK_RETRIES`, default 3), a stable `id` per event for deduplication, and no retry on a 4xx other than 408/429 — a refusal repeated is still a refusal | `test/konet/webhooks_test.exs` (8 tests, real HTTP listener) |
| **`sdk/go` depended on the archived `nhooyr.io/websocket`.** | `github.com/coder/websocket` — same project, new home; an import-path rename with no code change | `go build` / `vet` / `test -race` |
| **`install.sh` did not exist**, so `konet upgrade` fetched a 404 page. | written, POSIX `sh`, with checksum verification | run end to end against the real v0.3.0 release |
| **`install.sh` clobbered its caller's variables.** POSIX `sh` has no function-local scope, so `verify_checksum`'s `archive="$1"` overwrote the outer one and `tar` looked for `$tmp/$tmp/…`. | every helper's variables are prefixed | found by running it; the isolated install now succeeds |
| **`conformance/run.sh` leaked its server.** `mix phx.server` execs a BEAM that outlives the subshell, so the port stayed bound and the next run either failed or silently tested against a stale build. | cleanup kills whatever holds the port, and a pre-flight check refuses to start when it is already in use | three consecutive runs, 45/45 each, port free after |
| **Nothing ran an SDK against the real server.** | `conformance/` — 15 steps, three languages, one Phoenix server, in CI | `./conformance/run.sh` |
| **The CLI could not reach Docker Desktop on macOS.** `dockerclient.FromEnv` reads `DOCKER_HOST` and otherwise assumes `/var/run/docker.sock` — it does **not** read Docker CLI contexts. On a stock Docker Desktop install that socket does not exist (the daemon listens on `~/.docker/run/docker.sock`), so `start`/`stop`/`status`/`logs` all failed with "Is the docker daemon running?" *while it was running*. Colima and rootless Linux move it too. | `New()` honours `DOCKER_HOST` when set, otherwise probes Docker Desktop, Colima, `$XDG_RUNTIME_DIR` and `/var/run` in that order, pinging each; the error now lists what was tried | `internal/docker/docker_test.go` (5 tests), plus a full `init → keys → start → publish → logs → stop` run against a real daemon |

### Release and CI

| Was | Now |
|---|---|
| **`format_overrides` was two list entries**, so Windows shipped a `.tar.gz` the Scoop manifest does not expect | a single `{goos: windows, formats: [zip]}` entry |
| **`sdk/go` tests never ran in CI** (build + vet only) | `go test -race ./...` |
| **`sdk/python` tests never ran in CI** (`compileall` only) | `pip install -e '.[dev]'` + `pytest -q` |
| **`release-sdk-go.yml` swallowed push failures** with `\|\| echo`, leaving the job green with nothing published | `set -euo pipefail`, an explicit already-published check, then a failing push fails the job |
| **The Python release `sed` targeted the first `version = ` line in the file** and never touched `__version__` | a script that anchors on `[project]` and rewrites `__init__.py` too, failing loudly if either is not found |
| **`npm version` ran before `npm ci`**, mutating the lockfile before it was validated | `npm ci` first |
| **`konet-cli/README.md` had drifted from the root** and that stale copy shipped in every release archive | synced, plus a `cli-docs-in-sync` CI job that diffs both files and prints the fix |
| The server image did not receive the release version | `build-args: KONET_VERSION=${{ steps.meta.outputs.version }}` |

---

## Test counts, before and after

| Suite | Before | After |
|---|---|---|
| `konet-server` | 31 | 76 |
| `sdk/go` | 8 (binary framing only) | 16 |
| `sdk/python` | 12 (binary framing only) | 19 |
| `sdk/js` | 26 | 26 |
| `sdk/react-native` | 7 | 7 |
| `konet-cli` | 3 (config only) | 8 |
| **conformance** (3 SDKs × 15 steps, real server) | **0** | **45** |

CI additionally runs the Go SDK suite under `-race`, the Python suite at all,
and the conformance harness — none of which it did before.
