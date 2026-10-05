export { KonetClient } from "./client.js";
export type { ConnectionStatus, KonetClientOptions } from "./client.js";
export { Channel, KonetRequestError } from "./channel.js";
export type {
  BinaryMode,
  ChannelOptions,
  ChannelState,
  KonetBinaryError,
  KonetSendError,
} from "./channel.js";
export { Presence } from "./presence.js";
export type { BinaryFrame } from "./binary.js";
export type { PresenceMeta, PresenceEntry, PresenceMap, PresenceHandler } from "./presence.js";

import { KonetClient, KonetClientOptions } from "./client.js";

/**
 * Creates and connects a Konet client.
 *
 * @example
 * // The anon key printed by `konet keys generate` (a JWT), never a made-up string.
 * const client = createClient("ws://localhost:4000/socket", { token: process.env.KONET_ANON_KEY! });
 * const channel = client.channel("room:lobby");
 * await channel.subscribe();
 * channel.on("message", (payload) => console.log(payload));
 * channel.send("message", { text: "Hello!" });
 */
export function createClient(url: string, options: KonetClientOptions): KonetClient {
  return new KonetClient(url, options).connect();
}
