import { Presence, PresenceMap } from "./presence.js";

export type ChannelState = "idle" | "joining" | "joined" | "errored" | "leaving";

type EventHandler = (payload: unknown) => void;

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
  private nextRef: () => string;
  private isOpen: () => boolean;

  // Whether the application wants this channel joined. Survives socket drops,
  // so a reconnect knows what to restore; cleared only by unsubscribe(), so a
  // channel the caller deliberately left is never silently re-joined.
  private wantsJoin = false;
  private joinWaiters: JoinWaiter[] = [];
  private pendingSends: Map<string, ReturnType<typeof setTimeout>> = new Map();

  constructor(
    topic: string,
    sendFn: (msg: PhxMessage) => void,
    nextRef: () => string,
    isOpen: () => boolean
  ) {
    this.topic = topic;
    this.sendFn = sendFn;
    this.nextRef = nextRef;
    this.isOpen = isOpen;
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

  getPresence(): Presence {
    return this.presence;
  }

  /** @internal called by KonetClient when a message arrives for this topic */
  _receive(msg: PhxMessage): void {
    switch (msg.event) {
      case "phx_reply": {
        const resp = msg.payload as { status: string; response: unknown };
        const list = this.handlers.get(`phx_reply:${msg.ref}`) ?? [];
        list.forEach((h) => h(resp));
        this.handlers.delete(`phx_reply:${msg.ref}`);
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

    this.sendFn({
      joinRef: ref,
      ref,
      topic: this.topic,
      event: "phx_join",
      payload: {},
    });
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

  private emit(event: string, payload: unknown): void {
    (this.handlers.get(event) ?? []).forEach((h) => h(payload));
  }
}
