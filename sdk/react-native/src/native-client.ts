import { KonetClient, type KonetClientOptions } from "@raucheacho/konet-js";
import {
  resolveAppState,
  type AppStateLike,
  type AppStateSubscription,
} from "./app-state.js";

export interface KonetNativeClientOptions extends KonetClientOptions {
  /**
   * Supply the `AppState` implementation instead of resolving React Native's.
   * Pass `null` to opt out of foreground checks entirely. Mainly useful in
   * tests, or when driving the client from a different lifecycle source.
   */
  appState?: AppStateLike | null;
}

/**
 * A {@link KonetClient} that notices when the OS stops and restarts it.
 *
 * React Native suspends timers while an app is backgrounded, so a client can
 * come back to the foreground believing it is connected long after the server
 * timed the socket out — no close event ever fired. This subclass probes the
 * connection on every return to the foreground, which is the whole of what
 * React Native needs on top of the core client.
 */
export class KonetNativeClient extends KonetClient {
  private appState: AppStateLike | null;
  private subscription: AppStateSubscription | null = null;

  constructor(url: string, options: KonetNativeClientOptions) {
    const { appState, ...clientOptions } = options;
    super(url, clientOptions);
    this.appState = appState === undefined ? resolveAppState() : appState;
  }

  connect(): this {
    super.connect();
    this.watchAppState();
    return this;
  }

  disconnect(): void {
    this.unwatchAppState();
    super.disconnect();
  }

  private watchAppState(): void {
    if (this.subscription || !this.appState) return;

    this.subscription = this.appState.addEventListener("change", (state) => {
      if (state !== "active") return;
      this.checkConnection();
    });
  }

  private unwatchAppState(): void {
    this.subscription?.remove();
    this.subscription = null;
  }
}

/**
 * Create and connect a Konet client wired to the React Native app lifecycle.
 *
 * @example
 * const client = createNativeClient("wss://konet.example.com/socket", {
 *   token: session.konetToken,
 * });
 *
 * const map = client.channel("room:team-42:map");
 * await map.subscribe();
 * map.on("pos", (p) => updateMarker(p));
 */
export function createNativeClient(
  url: string,
  options: KonetNativeClientOptions
): KonetNativeClient {
  return new KonetNativeClient(url, options).connect();
}
