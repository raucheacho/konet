# 04.2 — `sdk/react-native` — `@raucheacho/konet-rn`

The smallest package in the repo, and deliberately so: **it implements none of
the protocol**. Three source files, ~160 lines total.

## Structure

```
sdk/react-native/
├── src/
│   ├── index.ts          re-exports + createNativeClient
│   ├── native-client.ts  KonetNativeClient extends KonetClient
│   ├── app-state.ts      lazy, guarded resolution of React Native's AppState
│   └── __tests__/native-client.test.ts
├── package.json          peerDeps: @raucheacho/konet-js >=0.3.0, react-native >=0.70
├── tsconfig.json         paths → ../js/src/index.ts
└── vitest.config.ts      alias → ../js/src/index.ts
```

No native module, no linking step: React Native provides the `WebSocket` global
the core is built on, and it supports `binaryType = "arraybuffer"` — so
`sendBinary()` and `acquireFloor()` work on a phone exactly as in a browser.

## What it adds

One thing. React Native suspends JS timers while an app is backgrounded, so a
client can return to the foreground believing it is connected long after the
server's 45 s timeout dropped the socket — with no `close` event ever fired.

```ts
export class KonetNativeClient extends KonetClient {
  connect(): this {
    super.connect();
    this.watchAppState();
    return this;
  }
  private watchAppState(): void {
    if (this.subscription || !this.appState) return;
    this.subscription = this.appState.addEventListener("change", (state) => {
      if (state !== "active") return;
      this.checkConnection();     // ← the entire feature
    });
  }
}
```

`checkConnection()` is public API on the core precisely so this subclass exists
without reaching into internals. See
[js.md](js.md#3-sockets-that-are-dead-but-do-not-know-it) for what it does.

## `app-state.ts` — why `require` is guarded

```ts
declare const require: ((id: string) => unknown) | undefined;

export function resolveAppState(): AppStateLike | null {
  if (typeof require !== "function") return null;
  try {
    const rn = require("react-native") as { AppState?: AppStateLike } | undefined;
    return rn?.AppState ?? null;
  } catch { return null; }
}
```

React Native is a peer dependency resolved **lazily**, so this module stays
importable outside a React Native runtime — unit tests, or a Node script sharing
code with the app — instead of throwing at import time. The package's
`react-native` entry field points Metro at the CJS build, where this `require`
resolves normally; anywhere else the guard short-circuits and the AppState
wiring is simply skipped.

`AppStateLike` is a hand-written structural type covering only `currentState`
and `addEventListener("change", …)` — the SDK never imports React Native's
types.

`KonetNativeClientOptions.appState` lets callers inject an implementation, or
pass `null` to opt out of foreground checks. The tests use it.

## The peer-dependency arrangement

This is the part that trips people up. The core is a **peer** dependency, not a
regular one, so there is exactly one copy of the protocol at runtime and core
fixes apply without republishing this package. But in the monorepo, the matching
core version does not exist on npm until the tag publishes it. Three files
conspire to make that work:

| File | Mechanism |
|---|---|
| `package.json` | `"build": "tsup … --external @raucheacho/konet-js --external react-native"` — the core is never inlined into `dist/` |
| `tsconfig.json` | `paths: {"@raucheacho/konet-js": ["../js/src/index.ts"]}` — typecheck and build resolve the sibling source |
| `vitest.config.ts` | the same alias, so tests run against the core's source |
| `ci.yml` / `release-sdk-rn.yml` | `npm ci --legacy-peer-deps` — stops npm trying to fetch a peer that is right here |

The peer range is `">=0.3.0"`, not `"^0.3.0"`, and the RN README explains why:
`^0.2.0` would reject the 0.3.0 core that ships alongside a 0.3.0 of this
package. Since every package is released in lockstep from one tag, a caret range
would break on every minor bump. Commit `1f7831f` ("Le SDK React Native exige
konet-js 0.3.0") is where the floor was raised, because floor control and binary
frames only exist from the 0.3.0 core.

⚠️ **Fragile — the `>=` range never expires.** Nothing stops npm from resolving
a much newer core against an old `konet-rn`. In lockstep releasing that is
harmless; if the two ever diverge, this range provides no protection.

## Public surface

`index.ts` re-exports the whole core so app code needs a single import:

```ts
export { KonetNativeClient, createNativeClient } from "./native-client.js";
export { KonetClient, Channel, Presence } from "@raucheacho/konet-js";
export type { KonetClientOptions, ChannelState, KonetSendError, BinaryFrame,
              PresenceMeta, PresenceEntry, PresenceMap, PresenceHandler }
  from "@raucheacho/konet-js";
```

Typical use:

```ts
const client = createNativeClient("wss://konet.example.com/socket", {
  token: session.konetToken,
});
const map = client.channel("room:team-42:map");
await map.subscribe();
map.on("pos", (p) => updateMarker(p));
```

## Tests

`src/__tests__/native-client.test.ts`, 7 tests, with a fake `AppState` that can
`emit(state)`:

- subscribes to AppState on connect;
- probes the connection on return to foreground;
- ignores `background`/`inactive` transitions;
- **reconnects and re-joins when the socket died while suspended** — the whole
  point of the package, end to end;
- removes the listener on `disconnect()`;
- does not probe after an explicit `disconnect()`;
- works as a plain client when AppState is unavailable.

## Publishing

CI job `sdk-react-native`: `npm ci --legacy-peer-deps` → `typecheck` → `test` →
`build`.

Release (`release-sdk-rn.yml`), on any `v*` tag:

```bash
npm version ${GITHUB_REF_NAME#v} --no-git-tag-version
npm ci --legacy-peer-deps
npm run build
npm publish --access public
```

The workflow carries a comment explaining that the peer range needs no
rewriting (it is `>=`, valid at every tag) and that the build never needs the
core to be on npm first — which matters because `release-sdk-js.yml` publishes
the core from the same tag, **in parallel**.
