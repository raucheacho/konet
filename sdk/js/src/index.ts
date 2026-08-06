export { KonetClient } from "./client.js";
export type { KonetClientOptions } from "./client.js";
export { Channel } from "./channel.js";
export type { ChannelState, KonetSendError } from "./channel.js";
export { Presence } from "./presence.js";
export type { PresenceMeta, PresenceEntry, PresenceMap, PresenceHandler } from "./presence.js";

import { KonetClient, KonetClientOptions } from "./client.js";

/**
 * Creates and connects a Konet client.
 *
 * @example
 * const client = createClient("ws://localhost:4000/socket", { token: "kt_anon_xxx" });
 * const channel = client.channel("room:lobby");
 * await channel.subscribe();
 * channel.on("message", (payload) => console.log(payload));
 * channel.send("message", { text: "Hello!" });
 */
export function createClient(url: string, options: KonetClientOptions): KonetClient {
  return new KonetClient(url, options).connect();
}
