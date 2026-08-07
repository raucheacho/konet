// React Native is a peer dependency and is resolved lazily, so this module
// stays importable outside a React Native runtime — unit tests, or a Node
// script sharing code with the app — instead of throwing at import time.
declare const require: ((id: string) => unknown) | undefined;

/** The subscription handle React Native's `addEventListener` returns. */
export interface AppStateSubscription {
  remove(): void;
}

/** The slice of React Native's `AppState` this SDK actually uses. */
export interface AppStateLike {
  readonly currentState: string | null;
  addEventListener(
    type: "change",
    listener: (state: string) => void
  ): AppStateSubscription;
}

/**
 * Resolve React Native's `AppState`, or null when there is no React Native
 * around.
 *
 * This package's `react-native` entry field points Metro at the CommonJS
 * build, where this `require` resolves normally. Anywhere else the guard
 * short-circuits and the AppState wiring is simply skipped.
 */
export function resolveAppState(): AppStateLike | null {
  if (typeof require !== "function") return null;

  try {
    const rn = require("react-native") as { AppState?: AppStateLike } | undefined;
    return rn?.AppState ?? null;
  } catch {
    return null;
  }
}
