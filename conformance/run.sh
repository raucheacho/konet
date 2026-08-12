#!/usr/bin/env bash
# Runs every SDK's conformance scenario against a real konet-server.
#
# The server is started here, on its own port with its own secret, so this can
# run alongside a development server without touching it.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${KONET_CONFORMANCE_PORT:-4009}"
SECRET="conformance-jwt-secret-at-least-32-chars!!"
SERVER_LOG="$(mktemp)"
SERVER_PID=""

info() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# Returns the pid(s) listening on $PORT, if any.
port_listeners() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null
    elif command -v fuser >/dev/null 2>&1; then
        fuser "$PORT"/tcp 2>/dev/null
    fi
}

# `mix phx.server` execs a BEAM that outlives the subshell we started, so
# killing $SERVER_PID alone leaves the port bound — and the next run then either
# fails to bind or, worse, silently tests against the stale server.
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        remaining="$(port_listeners)"
        [ -z "$remaining" ] && break
        # shellcheck disable=SC2086
        kill $remaining 2>/dev/null || true
        sleep 0.5
    done

    remaining="$(port_listeners)"
    if [ -n "$remaining" ]; then
        # shellcheck disable=SC2086
        kill -9 $remaining 2>/dev/null || true
    fi

    rm -f "$SERVER_LOG"
}
trap cleanup EXIT INT TERM

# Fail fast rather than test against something we did not start: a stale server
# on this port would be running a different build, and every result would be a
# lie about the code in this tree.
if [ -n "$(port_listeners)" ]; then
    echo "port $PORT is already in use — stop whatever is listening, or set KONET_CONFORMANCE_PORT" >&2
    exit 2
fi

# ── Mint two anon tokens with the secret the server will use ────────────────
#
# Two *identities*, not just two connections: Konet.Floor keys on the user id
# from the "sub" claim, so two sockets sharing a token are one holder and the
# second acquire is granted rather than refused. Reusing one token here made the
# refusal step fail, which is exactly the sort of contract detail this harness
# exists to pin.
info "Minting tokens"
TOKENS="$(
    cd "$ROOT/konet-server" && \
    KONET_JWT_SECRET="$SECRET" MIX_ENV=dev mix run --no-start -e '
      Application.put_env(:konet, :jwt_secret, System.get_env("KONET_JWT_SECRET"))
      {:ok, a} = Konet.Auth.sign(%{"role" => "anon", "sub" => "conformance-a"})
      {:ok, b} = Konet.Auth.sign(%{"role" => "anon", "sub" => "conformance-b"})
      IO.write(a <> " " <> b)
    ' 2>/dev/null
)"

TOKEN="${TOKENS%% *}"
TOKEN_B="${TOKENS##* }"

if [ -z "$TOKEN" ] || [ "$TOKEN" = "$TOKEN_B" ]; then
    echo "could not mint tokens — is konet-server compiled? try: (cd konet-server && mix compile)" >&2
    exit 2
fi
echo "tokens: ${TOKEN:0:20}… / ${TOKEN_B:0:20}…"

# ── Start the server ────────────────────────────────────────────────────────
info "Starting konet-server on :$PORT"
(
    cd "$ROOT/konet-server" && \
    KONET_JWT_SECRET="$SECRET" \
    KONET_PORT="$PORT" \
    KONET_HISTORY_LIMIT=50 \
    KONET_RATE_LIMIT=500 \
    KONET_CONN_RATE_LIMIT=1000 \
    KONET_RATE_LIMIT_BINARY=500 \
    MIX_ENV=dev \
    mix phx.server >"$SERVER_LOG" 2>&1
) &
SERVER_PID=$!

# ── Wait for readiness ──────────────────────────────────────────────────────
for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    echo "server never became healthy; log follows:" >&2
    cat "$SERVER_LOG" >&2
    exit 2
fi
echo "healthy: $(curl -fsS "http://127.0.0.1:$PORT/api/health")"

export KONET_URL="ws://127.0.0.1:$PORT/socket"
export KONET_TOKEN="$TOKEN"
export KONET_TOKEN_B="$TOKEN_B"

FAILED=0
run_sdk() {
    name="$1"; shift
    info "$name"
    if "$@"; then
        echo "→ $name OK"
    else
        echo "→ $name FAILED"
        FAILED=1
    fi
}

# ── JavaScript ──────────────────────────────────────────────────────────────
if [ -d "$ROOT/sdk/js/dist" ] || (cd "$ROOT/sdk/js" && npm run build >/dev/null 2>&1); then
    (cd "$ROOT/conformance/js" && [ -d node_modules ] || npm install --silent >/dev/null 2>&1) || true
    run_sdk "JavaScript" env KONET_ROOM="room:conf-js-$$" node "$ROOT/conformance/js/conformance.mjs"
else
    echo "skipping JavaScript: sdk/js failed to build" >&2
    FAILED=1
fi

# ── Go ──────────────────────────────────────────────────────────────────────
run_sdk "Go" env KONET_ROOM="room:conf-go-$$" sh -c "cd '$ROOT/conformance/go' && go run ."

# ── Python ──────────────────────────────────────────────────────────────────
# The SDK needs `websockets`; use a throwaway venv rather than whatever happens
# to be installed globally.
PYVENV="$ROOT/conformance/python/.venv"
if [ ! -x "$PYVENV/bin/python" ]; then
    info "Creating the Python venv"
    python3 -m venv "$PYVENV" >/dev/null 2>&1
    "$PYVENV/bin/pip" install -q -e "$ROOT/sdk/python" >/dev/null 2>&1
fi
run_sdk "Python" env KONET_ROOM="room:conf-py-$$" "$PYVENV/bin/python" "$ROOT/conformance/python/conformance.py"

info "Result"
if [ "$FAILED" -eq 0 ]; then
    echo "all SDKs conform"
else
    echo "at least one SDK failed; server log:"
    tail -40 "$SERVER_LOG"
fi
exit "$FAILED"
