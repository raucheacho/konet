import { Presence, PresenceMap } from "./presence.js";

export type ChannelState = "idle" | "joining" | "joined" | "errored" | "leaving";

type EventHandler = (payload: unknown) => void;

interface PhxMessage {
  joinRef: string | null;
  ref: string | null;
  topic: string;
  event: string;
  payload: unknown;
}

export class Channel {
  readonly topic: string;

  private state: ChannelState = "idle";
  private joinRef: string | null = null;
  private handlers: Map<string, EventHandler[]> = new Map();
  private presence: Presence = new Presence();
  private sendFn: (msg: PhxMessage) => void;
  private nextRef: () => string;

  constructor(
    topic: string,
    sendFn: (msg: PhxMessage) => void,
    nextRef: () => string
  ) {
    this.topic = topic;
    this.sendFn = sendFn;
    this.nextRef = nextRef;
  }

  subscribe(): Promise<void> {
    if (this.state === "joined" || this.state === "joining") {
      return Promise.resolve();
    }

    this.state = "joining";
    this.joinRef = this.nextRef();

    return new Promise((resolve, reject) => {
      const ref = this.joinRef!;

      this.onceReply(ref, (response: { status: string; response: unknown }) => {
        if (response.status === "ok") {
          this.state = "joined";
          resolve();
        } else {
          this.state = "errored";
          reject(new Error(`Failed to join ${this.topic}: ${JSON.stringify(response.response)}`));
        }
      });

      this.sendFn({
        joinRef: ref,
        ref,
        topic: this.topic,
        event: "phx_join",
        payload: {},
      });
    });
  }

  unsubscribe(): void {
    if (this.state !== "joined") return;

    this.state = "leaving";
    const ref = this.nextRef();

    this.sendFn({
      joinRef: this.joinRef,
      ref,
      topic: this.topic,
      event: "phx_leave",
      payload: {},
    });

    this.state = "idle";
    this.joinRef = null;
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

  send(event: string, payload: unknown = {}): void {
    if (this.state !== "joined") {
      throw new Error(`Channel ${this.topic} is not joined`);
    }

    this.sendFn({
      joinRef: this.joinRef,
      ref: this.nextRef(),
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

  private onceReply(ref: string, handler: (r: { status: string; response: unknown }) => void): void {
    const key = `phx_reply:${ref}`;
    this.handlers.set(key, [handler as EventHandler]);
  }

  private emit(event: string, payload: unknown): void {
    (this.handlers.get(event) ?? []).forEach((h) => h(payload));
  }
}
