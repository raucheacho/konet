export { KonetNativeClient, createNativeClient } from "./native-client.js";
export type { KonetNativeClientOptions } from "./native-client.js";
export type { AppStateLike, AppStateSubscription } from "./app-state.js";

// The protocol lives in @raucheacho/konet-js and is not reimplemented here.
// Re-exported so app code needs a single import even though the core stays a
// peer dependency (one copy at runtime, fixes to it apply without republishing
// this package).
//
// That includes binary frames and floor control: React Native's WebSocket
// supports `binaryType = "arraybuffer"`, so `channel.sendBinary()` and
// `channel.acquireFloor()` work on a phone exactly as they do in a browser,
// with no native module involved.
export { KonetClient, Channel, Presence } from "@raucheacho/konet-js";
export type {
  KonetClientOptions,
  ChannelState,
  KonetSendError,
  BinaryFrame,
  PresenceMeta,
  PresenceEntry,
  PresenceMap,
  PresenceHandler,
} from "@raucheacho/konet-js";
