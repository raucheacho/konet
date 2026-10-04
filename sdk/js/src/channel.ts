import { splitSender } from "./binary.js";
import { Presence, PresenceMap } from "./presence.js";

export type ChannelState = "idle" | "joining" | "joined" | "errored" | "leaving";

/**
 * How binary frames are shared on a topic.
 *
 * - `"exclusive"`: one sender at a time, arbitrated by the floor
 *   (`acquireFloor()`). Half-duplex: push-to-talk, a radio net.
 * - `"multiplex"`: every member sends whenever it likes. There is no floor at
 *   all. Full-duplex: a call.
 */
export type BinaryMode = "exclusive" | "multiplex";

export interface ChannelOptions {
  /**
   * Defaults to `"exclusive"`. The mode belongs to the topic, not to one
   * member: a join asking for a different mode from the members already there
   * is refused with `binary_mode_mismatch`, so every member of a topic must
   * ask for the same one.
   */
  binaryMode?: BinaryMode;
}

/**
 * `sender` is only set for a binary frame on a `"multiplex"` topic: the user id
 * of the member who sent it, as stamped by the server.
 */
type EventHandler = (payload: unknown, sender?: string) => void;

/**
 * Why the server refused binary frames, delivered as the channel's
 * `"binary_error"` event — at most once per reason per second.
 */
export interface KonetBinaryError {
  topic: string;
  /** `"floor_required"` (exclusive topic, floor not held) or `"rate_limited"`. */
  reason: string;
}

// Binary pushes carry refs with this prefix, so a refusal can be recognised
// without remembering anything per frame.
const BINARY_REF_PREFIX = "b";
// Refusals of the same reason closer together than this are reported once.
const BINARY_ERROR_INTERVAL_MS = 1_000;

/** Why the server refused a `send()`. */
export interface KonetSendError {
  topic: string;
  /** The application event name passed to `send()`. */
  event: string;
  payload: unknown;
  /** Server-supplied reason, e.g. "rate_limited". */
  reason: string;
}

interface PhxMessage {
  joinRef: string | null;
  ref: string | null;
  topic: string;
  event: string;
  payload: unknown;
}

interface JoinWaiter {
  resolve: () => void;
  reject: (error: Error) => void;
}

// Konet acknowledges a broadcast only when it refuses it, so a send that stays
// silent for this long is assumed to have gone through and stops being tracked.
const SEND_REPLY_GRACE_MS = 10_000;

export class Channel {
  readonly topic: string;

  private state: ChannelState = "idle";
  private joinRef: string | null = null;
  private handlers: Map<string, EventHandler[]> = new Map();
  private presence: Presence = new Presence();
  private sendFn: (msg: PhxMessage) => void;
  private sendBinaryFn: (
    joinRef: string,
    ref: string,
    topic: string,
    event: string,
    data: Uint8Array
  ) => void;
  private nextRef: () => string;
  private isOpen: () => boolean;
  private requestedBinaryMode: BinaryMode | undefined;
  private confirmedBinaryMode: BinaryMode | null = null;

  // Whether the application wants this channel joined. Survives socket drops,
  // so a reconnect knows what to restore; cleared only by unsubscribe(), so a
  // channel the caller deliberately left is never silently re-joined.
  private wantsJoin = false;
  private joinWaiters: JoinWaiter[] = [];
  private pendingSends: Map<string, ReturnType<typeof setTimeout>> = new Map();
  private binaryErrorAt: Map<string, number> = new Map();

  constructor(
    topic: string,
    sendFn: (msg: PhxMessage) => void,
    sendBinaryFn: (
      joinRef: string,
      ref: string,
      topic: string,
      event: string,
      data: Uint8Array
    ) => void,
    nextRef: () => string,
    isOpen: () => boolean,
    options: ChannelOptions = {}
  ) {
    this.topic = topic;
    this.sendFn = sendFn;
    this.sendBinaryFn = sendBinaryFn;
    this.nextRef = nextRef;
    this.isOpen = isOpen;
    this.requestedBinaryMode = options.binaryMode;
  }

  /** The mode asked for at creation; undefined means the server default. */
  get requestedMode(): BinaryMode | undefined {
    return this.requestedBinaryMode;
  }

  /**
   * The binary mode the server confirmed for this topic, or null until the
   * channel is joined. A server older than the mode reports nothing and is
   * read as `"exclusive"`, which is what it always did.
   */
  get binaryMode(): BinaryMode | null {
    return this.confirmedBinaryMode;
  }

  /**
   * Join the channel. Resolves once the server confirms.
   *
   * Safe to call before the socket is open: the join is issued as soon as the
   * connection is ready, through the same path a reconnect uses.
   */
  subscribe(): Promise<void> {
    this.wantsJoin = true;
    if (this.state === "joined") return Promise.resolve();

    const pending = new Promise<void>((resolve, reject) => {
      this.joinWaiters.push({ resolve, reject });
    });

    if (this.state !== "joining" && this.isOpen()) this.sendJoin();

    return pending;
  }

  unsubscribe(): void {
    this.wantsJoin = false;
    this.failJoinWaiters(new Error(`Left ${this.topic} before the join completed`));

    if (this.state === "joined" && this.isOpen()) {
      this.sendFn({
        joinRef: this.joinRef,
        ref: this.nextRef(),
        topic: this.topic,
        event: "phx_leave",
        payload: {},
      });
    }

    this.state = "idle";
    this.joinRef = null;
    this.clearPendingSends();
  }

  on(event: string, handler: EventHandler): () => void {
    const list = this.handlers.get(event) ?? [];
    list.push(handler);
    this.handlers.set(event, list);

    return () => {
      const updated = (this.handlers.get(event) ?? []).filter((h) => h !== handler);
      this.handlers.set(event, updated);
    };
  }

  /**
   * Broadcast an event to the other subscribers of this channel.
   *
   * Konet does not acknowledge accepted broadcasts, so there is nothing to
   * await — this stays fire-and-forget. It does reply when it *refuses* one
   * (rate limiting, an unsupported payload), and that reply is surfaced two
   * ways: through the optional `onError` callback for this specific call, and
   * as a channel-level `"send_error"` event for centralised logging.
   */
  send(
    event: string,
    payload: unknown = {},
    onError?: (error: KonetSendError) => void
  ): void {
    if (this.state !== "joined") {
      throw new Error(`Channel ${this.topic} is not joined`);
    }

    const ref = this.nextRef();
    this.trackSend(ref, event, payload, onError);

    this.sendFn({
      joinRef: this.joinRef,
      ref,
      topic: this.topic,
      event: "broadcast",
      payload: { event, payload },
    });
  }

  /**
   * Send a binary frame — audio, or anything else at a media rate.
   *
   * Different from `send()` in three ways that all follow from the rate:
   * Phoenix frames it natively instead of base64 inside JSON, the server never
   * acknowledges it, and in `"exclusive"` mode it is refused unless this
   * client holds the channel's floor — take it with `acquireFloor()` first.
   * In `"multiplex"` mode any member may send at any time, and receivers get
   * each frame with its sender as the handler's second argument:
   * `channel.on("a", (data, sender) => …)`.
   *
   * A refused frame is reported as a `"binary_error"` event on the channel
   * (`{ topic, reason }`), at most once per reason per second.
   *
   * `data` is copied into the frame, so the caller may reuse its buffer
   * immediately — which the audio path does, every 20 ms.
   */
  sendBinary(event: string, data: Uint8Array): void {
    if (this.state !== "joined") {
      throw new Error(`Channel ${this.topic} is not joined`);
    }
    // Not tracked like send(): at fifty frames a second a reply tracker per
    // frame would cost more than the frames do. The ref's prefix is enough to
    // recognise a refusal when one comes back; see "binary_error".
    this.sendBinaryFn(
      this.joinRef!,
      BINARY_REF_PREFIX + this.nextRef(),
      this.topic,
      event,
      data
    );
  }

  /**
   * Claim the right to send on this channel. At most one member holds it at a
   * time, so this is how half-duplex media — push-to-talk — is arbitrated.
   *
   * Resolves with the holder, which is this client on success. Rejects when
   * someone else already holds it, naming them so the UI can say who. Only in
   * `"exclusive"` mode: a `"multiplex"` topic has no floor, and the server
   * refuses with `floor_disabled`.
   */
  acquireFloor(): Promise<string> {
    return this.request("konet:floor_acquire").then(
      (response) => (response as { holder: string }).holder
    );
  }

  releaseFloor(): Promise<void> {
    return this.request("konet:floor_release").then(() => undefined);
  }

  /** A push that expects a reply, unlike the fire-and-forget `send()`. */
  private request(event: string, payload: unknown = {}): Promise<unknown> {
    if (this.state !== "joined") {
      return Promise.reject(new Error(`Channel ${this.topic} is not joined`));
    }

    const ref = this.nextRef();

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.handlers.delete(`phx_reply:${ref}`);
        reject(new Error(`${event} sans réponse`));
      }, SEND_REPLY_GRACE_MS);

      this.on(`phx_reply:${ref}`, (payload) => {
        clearTimeout(timer);
        const reply = payload as { status: string; response: unknown };
        if (reply.status === "ok") resolve(reply.response);
        else reject(new Error((reply.response as { reason?: string })?.reason ?? "refusé"));
      });

      this.sendFn({ joinRef: this.joinRef, ref, topic: this.topic, event, payload });
    });
  }

  getPresence(): Presence {
    return this.presence;
  }

  /** @internal a binary frame arrived for this topic */
  _receiveBinary(event: string, data: Uint8Array): void {
    // Several members send at once on a multiplex topic, so the server puts the
    // sender in front of every frame; without it the streams could not be told
    // apart. Keyed on the *confirmed* mode: a server older than modes accepts
    // the join, stays exclusive, and stamps nothing.
    if (this.confirmedBinaryMode !== "multiplex") {
      this.emit(event, data);
      return;
    }
    const frame = splitSender(data);
    if (frame === null) return;
    this.emit(event, frame.data, frame.sender);
  }

  /** @internal called by KonetClient when a message arrives for this topic */
  _receive(msg: PhxMessage): void {
    switch (msg.event) {
      case "phx_reply": {
        const resp = msg.payload as { status: string; response: unknown };
        const list = this.handlers.get(`phx_reply:${msg.ref}`) ?? [];
        list.forEach((h) => h(resp));
        this.handlers.delete(`phx_reply:${msg.ref}`);
        if (list.length === 0 && msg.ref?.startsWith(BINARY_REF_PREFIX)) {
          this.binaryRefused(resp);
        }
        break;
      }

      case "presence_state":
        this.presence.syncState(msg.payload as PresenceMap);
        this.emit("presence", this.presence.list());
        break;

      case "presence_diff":
        this.presence.syncDiff(msg.payload as { joins: PresenceMap; leaves: PresenceMap });
        this.emit("presence", this.presence.list());
        break;

      case "phx_error":
        this.state = "errored";
        this.emit("error", msg.payload);
        break;

      case "phx_close":
        this.state = "idle";
        break;

      default:
        this.emit(msg.event, msg.payload);
    }
  }

  /** @internal the socket is (re)open — restore the join the server lost */
  _rejoin(): void {
    if (!this.wantsJoin) return;
    if (this.state === "joined" || this.state === "joining") return;
    this.sendJoin();
  }

  /** @internal the socket went away, taking the server-side join with it */
  _socketClosed(): void {
    if (this.state === "joined" || this.state === "joining") this.state = "idle";
    this.joinRef = null;
    this.confirmedBinaryMode = null;

    // Konet only replies to a broadcast it refused, so an in-flight send whose
    // socket died is indistinguishable from one that was accepted. Drop the
    // trackers rather than invent a failure that may not have happened.
    this.clearPendingSends();
  }

  private sendJoin(): void {
    this.state = "joining";
    const ref = this.nextRef();
    this.joinRef = ref;

    this.onceReply(ref, (response: { status: string; response: unknown }) => {
      // A reply from a join that a reconnect already superseded.
      if (this.joinRef !== ref) return;

      if (response.status === "ok") {
        this.state = "joined";
        const reply = response.response as { binary_mode?: BinaryMode } | null;
        this.confirmedBinaryMode = reply?.binary_mode ?? "exclusive";
        this.resolveJoinWaiters();
      } else {
        this.state = "errored";
        // wantsJoin stays set: a rejection is often a stale or expired token,
        // and the next reconnect should try again with whatever token the
        // client holds by then.
        this.failJoinWaiters(
          new Error(`Failed to join ${this.topic}: ${JSON.stringify(response.response)}`)
        );
        this.emit("error", response.response);
      }
    });

    // Sent on every join, reconnects included: the server forgets a topic's
    // mode once it empties, so a rejoin that dropped it would come back as
    // whatever the server defaults to.
    this.sendFn({
      joinRef: ref,
      ref,
      topic: this.topic,
      event: "phx_join",
      payload: this.requestedBinaryMode ? { binary_mode: this.requestedBinaryMode } : {},
    });
  }

  /**
   * A binary frame was refused. They used to vanish without a trace — lost
   * audio, impossible to diagnose. The server already answers at most once per
   * reason per second; the same window here keeps an older server, which
   * answers every frame, from flooding the application.
   */
  private binaryRefused(resp: { status: string; response: unknown }): void {
    if (resp.status === "ok") return;
    const reason = (resp.response as { reason?: string } | null)?.reason ?? "unknown";
    const now = Date.now();
    const last = this.binaryErrorAt.get(reason);
    if (last !== undefined && now - last < BINARY_ERROR_INTERVAL_MS) return;
    this.binaryErrorAt.set(reason, now);
    const error: KonetBinaryError = { topic: this.topic, reason };
    this.emit("binary_error", error);
  }

  private trackSend(
    ref: string,
    event: string,
    payload: unknown,
    onError?: (error: KonetSendError) => void
  ): void {
    const timer = setTimeout(() => {
      this.handlers.delete(`phx_reply:${ref}`);
      this.pendingSends.delete(ref);
    }, SEND_REPLY_GRACE_MS);

    this.pendingSends.set(ref, timer);

    this.onceReply(ref, (response: { status: string; response: unknown }) => {
      const pending = this.pendingSends.get(ref);
      if (pending) clearTimeout(pending);
      this.pendingSends.delete(ref);

      if (response.status === "ok") return;

      const reason =
        (response.response as { reason?: string } | null)?.reason ?? "unknown";
      const error: KonetSendError = { topic: this.topic, event, payload, reason };

      onError?.(error);
      this.emit("send_error", error);
    });
  }

  private clearPendingSends(): void {
    for (const [ref, timer] of this.pendingSends) {
      clearTimeout(timer);
      this.handlers.delete(`phx_reply:${ref}`);
    }
    this.pendingSends.clear();
  }

  private resolveJoinWaiters(): void {
    const waiters = this.joinWaiters;
    this.joinWaiters = [];
    waiters.forEach((w) => w.resolve());
  }

  private failJoinWaiters(error: Error): void {
    const waiters = this.joinWaiters;
    this.joinWaiters = [];
    waiters.forEach((w) => w.reject(error));
  }

  private onceReply(ref: string, handler: (r: { status: string; response: unknown }) => void): void {
    const key = `phx_reply:${ref}`;
    this.handlers.set(key, [handler as EventHandler]);
  }

  private emit(event: string, payload: unknown, sender?: string): void {
    (this.handlers.get(event) ?? []).forEach((h) => h(payload, sender));
  }
}
